-- 008_review_approval_and_rewards.sql
--
-- Phase 4: the studio reviews each piece of feedback, and approving it pays
-- the tester. Rewards are any mix of Grogu reputation, a game key, and money.
--
--  * feedback.review_status: submitted -> approved | rejected. Only the studio
--    that owns the playtest decides, and only once.
--  * game_keys: a per-game inventory of keys. Approval with a key takes one
--    unused key under a row lock (FOR UPDATE SKIP LOCKED), and a unique index
--    on feedback_id means a review can never hold two keys. Two approvals
--    therefore never receive the same key. The key itself is not shown to the
--    tester: per the brief, the tester is told to check their email, and the
--    studio sees which key went to whom so it can send it.
--  * ledger_entries: money is a ledger, not a balance column. A tester's
--    available balance is the sum of their entries. Entries are append-only.
--    No payment method is integrated; amounts are whole Indian rupees.
--  * reputation_events: every change to a tester's reputation is an event with
--    a reason. players.reputation is now a cache of the sum, kept in step by
--    grogu_reputation_award(). Existing reputation is carried over as one
--    "baseline" event per tester so the cache and the ledger agree from here on.
--  * reputation_rules: the amount for each reason lives in a table, not in
--    code, so the rule set can be tuned without a migration.
--
-- Additive and idempotent. Existing /api/v1 response shapes only gain fields.

BEGIN;

/* -------------------------------------------------------------------------- */
/*  Review state on feedback                                                   */
/* -------------------------------------------------------------------------- */

ALTER TABLE feedback ADD COLUMN IF NOT EXISTS review_status varchar(16) NOT NULL DEFAULT 'submitted';
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS review_note   text;
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS reviewed_at   timestamptz;

ALTER TABLE feedback DROP CONSTRAINT IF EXISTS feedback_review_status_check;
ALTER TABLE feedback ADD  CONSTRAINT feedback_review_status_check
  CHECK (review_status IN ('submitted', 'approved', 'rejected'));

/* -------------------------------------------------------------------------- */
/*  Notification types                                                         */
/* -------------------------------------------------------------------------- */

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD  CONSTRAINT notifications_type_check
  CHECK (type IN ('application-accepted', 'application-rejected', 'application-received',
                  'feedback-received', 'playtest-published', 'test-reminder', 'system',
                  'feedback-approved', 'feedback-rejected', 'game-key-sent'));

/* -------------------------------------------------------------------------- */
/*  Game-key inventory                                                         */
/* -------------------------------------------------------------------------- */
-- A key is available while allocated_at is NULL. feedback_id goes NULL rather
-- than taking the key back if a review is deleted through the legacy API, so a
-- key that was handed out is never handed out again.

CREATE TABLE IF NOT EXISTS game_keys (
  id           serial PRIMARY KEY,
  game_id      integer     NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  code         text        NOT NULL,
  feedback_id  integer     REFERENCES feedback(id) ON DELETE SET NULL,
  allocated_to integer     REFERENCES users(id) ON DELETE SET NULL,
  allocated_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT game_keys_code_check CHECK (length(code) BETWEEN 1 AND 200)
);

CREATE UNIQUE INDEX IF NOT EXISTS game_keys_game_code_key ON game_keys (game_id, code);
CREATE UNIQUE INDEX IF NOT EXISTS game_keys_feedback_key  ON game_keys (feedback_id) WHERE feedback_id IS NOT NULL;
CREATE INDEX        IF NOT EXISTS game_keys_available_idx ON game_keys (game_id, id) WHERE allocated_at IS NULL;

/* -------------------------------------------------------------------------- */
/*  Money ledger                                                               */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS ledger_entries (
  id          serial PRIMARY KEY,
  user_id     integer     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Whole rupees. Credits are positive; a future payout would be negative.
  amount      integer     NOT NULL,
  kind        varchar(32) NOT NULL,
  playtest_id integer     REFERENCES playtests(id) ON DELETE SET NULL,
  feedback_id integer     REFERENCES feedback(id) ON DELETE SET NULL,
  created_by  integer     REFERENCES users(id) ON DELETE SET NULL,
  note        text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ledger_entries_kind_check   CHECK (kind IN ('review-reward', 'payout', 'adjustment')),
  CONSTRAINT ledger_entries_amount_check CHECK (amount <> 0)
);

CREATE INDEX IF NOT EXISTS ledger_entries_user_idx ON ledger_entries (user_id, created_at DESC);
-- One cash reward per review, however many times approval is attempted.
CREATE UNIQUE INDEX IF NOT EXISTS ledger_entries_review_reward_key
  ON ledger_entries (feedback_id) WHERE kind = 'review-reward';

-- Append-only: an entry's amount, owner and kind never change after it is
-- written. (Foreign-key actions may still null out playtest/feedback links.)
CREATE OR REPLACE FUNCTION grogu_ledger_guard() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.amount <> OLD.amount OR NEW.user_id <> OLD.user_id OR NEW.kind <> OLD.kind THEN
    RAISE EXCEPTION 'Ledger entries cannot be changed. Write a new entry instead.' USING ERRCODE = 'GR003';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ledger_entries_guard ON ledger_entries;
CREATE TRIGGER ledger_entries_guard BEFORE UPDATE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION grogu_ledger_guard();

/* -------------------------------------------------------------------------- */
/*  Reputation rules and events                                                */
/* -------------------------------------------------------------------------- */
-- `amount` is what a fixed rule awards. A variable rule takes its amount from
-- the caller (the studio's bonus, a carried-over baseline), defaulting to
-- `amount` and capped by `max_amount` when that is set.
--
-- Re-running this migration never overwrites a rule, so amounts tuned in the
-- database survive.

CREATE TABLE IF NOT EXISTS reputation_rules (
  reason      varchar(48) PRIMARY KEY,
  amount      integer     NOT NULL,
  variable    boolean     NOT NULL DEFAULT false,
  max_amount  integer,
  category    varchar(16) NOT NULL,
  label       text        NOT NULL,
  description text        NOT NULL DEFAULT '',
  active      boolean     NOT NULL DEFAULT true,
  position    integer     NOT NULL DEFAULT 0,
  CONSTRAINT reputation_rules_category_check
    CHECK (category IN ('profile', 'participation', 'review', 'other'))
);

INSERT INTO reputation_rules (reason, amount, variable, max_amount, category, label, description, position) VALUES
  ('baseline',        0,  true,  NULL, 'other',  'Starting reputation',
   'Reputation earned before the reputation history was kept.', 100),
  ('review-approved', 15, false, NULL, 'review', 'Review approved',
   'The studio approved your review.', 40),
  ('review-bonus',    0,  true,  50,   'review', 'Studio bonus',
   'Extra reputation a studio adds when a review was especially useful.', 50)
ON CONFLICT (reason) DO NOTHING;

-- scope_key makes "once" explicit: one event per (tester, reason, scope). The
-- scope is '' for once-ever rules, otherwise the playtest or feedback id.
CREATE TABLE IF NOT EXISTS reputation_events (
  id          serial PRIMARY KEY,
  user_id     integer     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason      varchar(48) NOT NULL REFERENCES reputation_rules(reason),
  scope_key   text        NOT NULL DEFAULT '',
  amount      integer     NOT NULL,
  playtest_id integer     REFERENCES playtests(id) ON DELETE SET NULL,
  feedback_id integer     REFERENCES feedback(id) ON DELETE SET NULL,
  created_by  integer     REFERENCES users(id) ON DELETE SET NULL,
  note        text        NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reputation_events_once UNIQUE (user_id, reason, scope_key)
);

CREATE INDEX IF NOT EXISTS reputation_events_user_idx     ON reputation_events (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reputation_events_feedback_idx ON reputation_events (feedback_id) WHERE feedback_id IS NOT NULL;

-- Carry existing reputation over, once per tester, so that from here on
-- players.reputation = sum(reputation_events.amount).
INSERT INTO reputation_events (user_id, reason, scope_key, amount, note, created_at)
SELECT pl.user_id, 'baseline', '', pl.reputation, '', u.created_at
  FROM players pl
  JOIN users u ON u.id = pl.user_id
 WHERE pl.reputation <> 0
ON CONFLICT (user_id, reason, scope_key) DO NOTHING;

-- A new tester now starts at zero and earns from there; the old default of 50
-- would put reputation in the cache that no event accounts for.
ALTER TABLE players ALTER COLUMN reputation SET DEFAULT 0;

/* -------------------------------------------------------------------------- */
/*  Helpers                                                                    */
/* -------------------------------------------------------------------------- */

-- A whole number from a request body, or p_min when the key is absent.
CREATE OR REPLACE FUNCTION grogu_int_field(
  p_input jsonb, p_key text, p_min integer, p_max integer, p_label text
) RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v jsonb := p_input -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN p_min;
  END IF;
  IF jsonb_typeof(v) <> 'number' OR (v #>> '{}') !~ '^-?\d+$' THEN
    RAISE EXCEPTION '% must be a whole number.', p_label USING ERRCODE = 'GR005';
  END IF;
  IF (v #>> '{}')::numeric NOT BETWEEN p_min AND p_max THEN
    RAISE EXCEPTION '% must be between % and %.', p_label, p_min, p_max USING ERRCODE = 'GR005';
  END IF;
  RETURN (v #>> '{}')::int;
END;
$$;

CREATE OR REPLACE FUNCTION grogu_bool_field(p_input jsonb, p_key text) RETURNS boolean
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v jsonb := p_input -> p_key;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(v) <> 'boolean' THEN
    RAISE EXCEPTION '% must be true or false.', p_key USING ERRCODE = 'GR005';
  END IF;
  RETURN v::text::boolean;
END;
$$;

CREATE OR REPLACE FUNCTION grogu_rupees(p_amount integer) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT '₹' || to_char(p_amount, 'FM99,99,99,999');
$$;

/* -------------------------------------------------------------------------- */
/*  Awarding reputation                                                        */
/* -------------------------------------------------------------------------- */
-- The only way reputation changes. Inserts the event and moves the cache in
-- the same transaction. Idempotent: a second award for the same
-- (tester, reason, scope) inserts nothing and returns 0, and two concurrent
-- ones are serialised by the unique constraint. The cache is moved by
-- increment, which is safe under concurrent awards to the same tester.
--
-- Returns the amount actually awarded. Non-testers and inactive rules get 0.

CREATE OR REPLACE FUNCTION grogu_reputation_award(
  p_user_id     integer,
  p_reason      text,
  p_scope       text,
  p_amount      integer DEFAULT NULL,
  p_note        text    DEFAULT '',
  p_playtest_id integer DEFAULT NULL,
  p_feedback_id integer DEFAULT NULL,
  p_created_by  integer DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  r        reputation_rules;
  v_amount integer;
  v_id     integer;
BEGIN
  SELECT * INTO r FROM reputation_rules WHERE reason = p_reason;
  IF r.reason IS NULL THEN
    RAISE EXCEPTION 'Unknown reputation rule "%".', p_reason;
  END IF;
  IF NOT r.active OR NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND role = 'Player') THEN
    RETURN 0;
  END IF;

  v_amount := CASE WHEN r.variable THEN coalesce(p_amount, r.amount) ELSE r.amount END;
  IF r.max_amount IS NOT NULL AND v_amount > r.max_amount THEN
    RAISE EXCEPTION '% can be at most %.', r.label, r.max_amount USING ERRCODE = 'GR005';
  END IF;
  IF v_amount = 0 THEN
    RETURN 0;
  END IF;

  PERFORM grogu_player_id(p_user_id);

  INSERT INTO reputation_events (user_id, reason, scope_key, amount, playtest_id, feedback_id, created_by, note)
  VALUES (p_user_id, p_reason, coalesce(p_scope, ''), v_amount, p_playtest_id, p_feedback_id,
          p_created_by, coalesce(p_note, ''))
  ON CONFLICT (user_id, reason, scope_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE players SET reputation = reputation + v_amount WHERE user_id = p_user_id;
  RETURN v_amount;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  JSON                                                                       */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_feedback_json(f feedback) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',         f.id::text,
    'playtestId', f.playtest_id::text,
    'testerId',   (SELECT pl.user_id::text FROM players pl WHERE pl.id = f.player_id),
    'ratings',    jsonb_build_object(
                    'fun',         f.rating_fun,
                    'difficulty',  f.rating_difficulty,
                    'clarity',     f.rating_clarity,
                    'performance', f.rating_performance,
                    'polish',      f.rating_polish),
    'sentiment',       f.sentiment,
    'summary',         f.summary,
    'highlights',      to_jsonb(f.highlights),
    'painPoints',      to_jsonb(f.pain_points),
    'bugs',            to_jsonb(f.bugs),
    'answers',         f.answers,
    'wouldRecommend',  f.would_recommend,
    'hoursPlayed',     f.hours_played::float8,
    'media',           f.media,
    'submittedAt',     grogu_iso(f.created_at),
    'reviewStatus',    f.review_status,
    'reviewNote',      f.review_note,
    'reviewedAt',      grogu_iso(f.reviewed_at),
    -- What the studio granted for this review. Zero until it is approved.
    'rewards', jsonb_build_object(
      'reputation', (SELECT coalesce(sum(e.amount), 0) FROM reputation_events e
                      WHERE e.feedback_id = f.id AND e.reason IN ('review-approved', 'review-bonus')),
      'cash',       (SELECT coalesce(sum(l.amount), 0) FROM ledger_entries l
                      WHERE l.feedback_id = f.id AND l.kind = 'review-reward'),
      'gameKey',    EXISTS (SELECT 1 FROM game_keys k WHERE k.feedback_id = f.id))
  );
$$;

-- Keys are only ever serialised for the studio that owns the game.
CREATE OR REPLACE FUNCTION grogu_game_key_json(k game_keys) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',          k.id::text,
    'gameId',      k.game_id::text,
    'code',        k.code,
    'status',      CASE WHEN k.allocated_at IS NULL THEN 'available' ELSE 'allocated' END,
    'allocatedTo', k.allocated_to::text,
    'feedbackId',  k.feedback_id::text,
    'allocatedAt', grogu_iso(k.allocated_at),
    'createdAt',   grogu_iso(k.created_at)
  );
$$;

CREATE OR REPLACE FUNCTION grogu_ledger_entry_json(l ledger_entries) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',         l.id::text,
    'userId',     l.user_id::text,
    'amount',     l.amount,
    'kind',       l.kind,
    'playtestId', l.playtest_id::text,
    'feedbackId', l.feedback_id::text,
    'note',       l.note,
    'createdAt',  grogu_iso(l.created_at)
  );
$$;

/* -------------------------------------------------------------------------- */
/*  Game keys                                                                  */
/* -------------------------------------------------------------------------- */

-- Adds keys to one of the caller's games. Blank lines and duplicates (within
-- the paste or against keys already stored) are skipped, not errors.
CREATE OR REPLACE FUNCTION grogu_game_keys_add(
  p_user_id integer, p_game_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_codes text[];
  v_added integer;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  IF NOT EXISTS (SELECT 1 FROM games WHERE id = p_game_id AND developer_user_id = p_user_id) THEN
    RAISE EXCEPTION 'Game not found.' USING ERRCODE = 'GR001';
  END IF;
  IF jsonb_typeof(p_input -> 'codes') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Send the keys as a list.' USING ERRCODE = 'GR005';
  END IF;

  SELECT coalesce(array_agg(DISTINCT c), '{}')
    INTO v_codes
    FROM (SELECT btrim(value) AS c FROM jsonb_array_elements_text(p_input -> 'codes')) s
   WHERE c <> '';

  IF cardinality(v_codes) = 0 THEN
    RAISE EXCEPTION 'Paste at least one key.' USING ERRCODE = 'GR005';
  END IF;
  IF cardinality(v_codes) > 500 THEN
    RAISE EXCEPTION 'Add at most 500 keys at a time.' USING ERRCODE = 'GR005';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_codes) c WHERE length(c) > 200) THEN
    RAISE EXCEPTION 'A key can be at most 200 characters.' USING ERRCODE = 'GR005';
  END IF;

  INSERT INTO game_keys (game_id, code)
  SELECT p_game_id, c FROM unnest(v_codes) c
  ON CONFLICT (game_id, code) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;

  RETURN jsonb_build_object(
    'added',   v_added,
    'skipped', cardinality(v_codes) - v_added,
    'keys',    coalesce((SELECT jsonb_agg(grogu_game_key_json(k) ORDER BY k.id)
                           FROM game_keys k WHERE k.game_id = p_game_id), '[]'::jsonb));
END;
$$;

-- Removes an unused key. A key already given to a tester stays, as a record.
CREATE OR REPLACE FUNCTION grogu_game_key_delete(
  p_user_id integer, p_game_id integer, p_key_id integer
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  DELETE FROM game_keys k
   USING games g
   WHERE k.id = p_key_id
     AND k.game_id = p_game_id
     AND g.id = k.game_id
     AND g.developer_user_id = p_user_id
     AND k.allocated_at IS NULL
  RETURNING k.id INTO v_id;

  IF v_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM game_keys k JOIN games g ON g.id = k.game_id
                WHERE k.id = p_key_id AND k.game_id = p_game_id AND g.developer_user_id = p_user_id) THEN
      RAISE EXCEPTION 'That key was already given to a tester, so it can''t be removed.' USING ERRCODE = 'GR003';
    END IF;
    RAISE EXCEPTION 'Key not found.' USING ERRCODE = 'GR001';
  END IF;

  RETURN jsonb_build_object('id', v_id::text);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Reviewing feedback                                                         */
/* -------------------------------------------------------------------------- */
-- p_input: { decision: "approved" | "rejected", note?, reputationBonus?,
--            cashAmount?, gameKey? }. Rewards are ignored on a rejection.
--
-- Concurrency: the feedback row is locked first, so a second decision on the
-- same review waits and then finds it already decided. The game key is taken
-- with SKIP LOCKED, so two approvals for different reviews of the same game
-- each get a different key instead of queueing on the same row. Every write
-- is in one transaction: if no key is left, nothing is approved or paid.

CREATE OR REPLACE FUNCTION grogu_feedback_review(
  p_user_id integer, p_feedback_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  f          feedback;
  p          playtests;
  g          games;
  k          game_keys;
  v_studio   integer;
  v_tester   integer;
  v_decision text := lower(coalesce(p_input ->> 'decision', ''));
  v_note     text := nullif(btrim(coalesce(p_input ->> 'note', '')), '');
  v_bonus    integer;
  v_cash     integer;
  v_key      boolean;
  v_rep      integer;
  v_parts    text[] := '{}';
  v_title    text;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  v_studio := grogu_studio_id(p_user_id);

  IF v_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Decision must be approved or rejected.' USING ERRCODE = 'GR005';
  END IF;
  IF length(coalesce(v_note, '')) > 1000 THEN
    RAISE EXCEPTION 'Keep the note under 1000 characters.' USING ERRCODE = 'GR005';
  END IF;

  v_bonus := grogu_int_field(p_input, 'reputationBonus', 0,
               coalesce((SELECT max_amount FROM reputation_rules WHERE reason = 'review-bonus'), 0),
               'The reputation bonus');
  v_cash  := grogu_int_field(p_input, 'cashAmount', 0, 100000, 'The cash reward');
  v_key   := grogu_bool_field(p_input, 'gameKey');

  SELECT f2.* INTO f
    FROM feedback f2
    JOIN playtests p2 ON p2.id = f2.playtest_id
   WHERE f2.id = p_feedback_id AND p2.studio_id = v_studio
     FOR UPDATE OF f2;

  IF f.id IS NULL THEN
    RAISE EXCEPTION 'Review not found.' USING ERRCODE = 'GR001';
  END IF;
  IF f.review_status <> 'submitted' THEN
    RAISE EXCEPTION 'This review was already %.', f.review_status USING ERRCODE = 'GR003';
  END IF;

  SELECT * INTO p FROM playtests WHERE id = f.playtest_id;
  SELECT * INTO g FROM games WHERE id = p.game_id;
  SELECT pl.user_id INTO v_tester FROM players pl WHERE pl.id = f.player_id;
  v_title := coalesce(p.title, p.game_name);

  IF v_decision = 'rejected' THEN
    UPDATE feedback SET review_status = 'rejected', review_note = v_note, reviewed_at = now()
     WHERE id = f.id
    RETURNING * INTO f;

    PERFORM grogu_notify(
      v_tester, 'feedback-rejected',
      'Update on your review of ' || v_title,
      coalesce(v_note, 'The studio didn''t approve this review, so no rewards were issued.'),
      '/tests/' || p.id);

    RETURN grogu_feedback_json(f);
  END IF;

  -- Take the key first: if there is none, fail before anything is written.
  IF v_key THEN
    SELECT * INTO k FROM game_keys
     WHERE game_id = p.game_id AND allocated_at IS NULL
     ORDER BY id
     LIMIT 1
       FOR UPDATE SKIP LOCKED;

    IF k.id IS NULL THEN
      RAISE EXCEPTION 'There are no unused keys left for %. Add keys to the game, or approve without one.',
        coalesce(g.title, 'this game') USING ERRCODE = 'GR003';
    END IF;

    UPDATE game_keys SET feedback_id = f.id, allocated_to = v_tester, allocated_at = now()
     WHERE id = k.id;
  END IF;

  UPDATE feedback SET review_status = 'approved', review_note = v_note, reviewed_at = now()
   WHERE id = f.id
  RETURNING * INTO f;

  v_rep := grogu_reputation_award(v_tester, 'review-approved', f.id::text, NULL, '', p.id, f.id, p_user_id)
         + grogu_reputation_award(v_tester, 'review-bonus', f.id::text, v_bonus, coalesce(v_note, ''), p.id, f.id, p_user_id);

  IF v_cash > 0 THEN
    INSERT INTO ledger_entries (user_id, amount, kind, playtest_id, feedback_id, created_by, note)
    VALUES (v_tester, v_cash, 'review-reward', p.id, f.id, p_user_id, 'Reward for your review of ' || v_title);
  END IF;

  IF v_rep > 0 THEN
    v_parts := v_parts || ('+' || v_rep || ' reputation');
  END IF;
  IF v_cash > 0 THEN
    v_parts := v_parts || (grogu_rupees(v_cash) || ' added to your balance');
  END IF;
  IF v_key THEN
    v_parts := v_parts || 'a game key'::text;
  END IF;

  PERFORM grogu_notify(
    v_tester, 'feedback-approved',
    'Your review of ' || v_title || ' was approved',
    CASE WHEN cardinality(v_parts) = 0 THEN 'Thanks for the review.'
         ELSE 'You earned ' || array_to_string(v_parts, ', ') || '.' END
    || CASE WHEN v_note IS NULL THEN '' ELSE ' "' || v_note || '"' END,
    '/rewards');

  IF v_key THEN
    PERFORM grogu_notify(
      v_tester, 'game-key-sent',
      'Your ' || coalesce(g.title, 'game') || ' key is on its way',
      'The studio is sending your game key by email. Check your inbox (and spam folder).',
      '/rewards');
  END IF;

  RETURN grogu_feedback_json(f);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Bootstrap                                                                  */
/* -------------------------------------------------------------------------- */
-- The collections added from Phase 4 on are built in grogu_bootstrap_extras()
-- so later phases replace that small function instead of the whole bootstrap.

CREATE OR REPLACE FUNCTION grogu_bootstrap_extras(p_viewer_id integer, p_role text) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    -- A studio's key inventory, codes included. Nobody else receives keys.
    'gameKeys', CASE WHEN p_role = 'developer' THEN
      coalesce((SELECT jsonb_agg(grogu_game_key_json(k) ORDER BY k.game_id, k.id)
                  FROM game_keys k JOIN games g ON g.id = k.game_id
                 WHERE g.developer_user_id = p_viewer_id), '[]'::jsonb)
      ELSE '[]'::jsonb END,

    -- The viewer's own money ledger.
    'ledgerEntries', coalesce((SELECT jsonb_agg(grogu_ledger_entry_json(l) ORDER BY l.created_at DESC, l.id DESC)
                                 FROM ledger_entries l WHERE l.user_id = p_viewer_id), '[]'::jsonb),

    'wallet', CASE WHEN p_role = 'tester' THEN jsonb_build_object(
      'balance', (SELECT coalesce(sum(l.amount), 0) FROM ledger_entries l WHERE l.user_id = p_viewer_id))
      ELSE NULL END
  );
$$;

CREATE OR REPLACE FUNCTION grogu_bootstrap(p_viewer_id integer) RETURNS jsonb
  LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_role       text;
  v_player_id  integer;
  v_studio_id  integer;
  v_result     jsonb;
BEGIN
  SELECT grogu_role_to_api(role) INTO v_role FROM users WHERE id = p_viewer_id;
  SELECT id INTO v_player_id FROM players WHERE user_id = p_viewer_id;
  SELECT id INTO v_studio_id FROM studios WHERE user_id = p_viewer_id;

  SELECT jsonb_build_object(

    'session', CASE WHEN v_role IS NULL THEN NULL ELSE
      (SELECT jsonb_build_object('user', grogu_user_json(u, p_viewer_id), 'role', v_role)
         FROM users u WHERE u.id = p_viewer_id) END,

    -- Public directory: every user, with emails masked to all but the viewer.
    'users', coalesce((SELECT jsonb_agg(grogu_user_json(u, p_viewer_id) ORDER BY u.id)
                         FROM users u WHERE u.role <> 'Admin'), '[]'::jsonb),

    'testerProfiles', coalesce((SELECT jsonb_agg(grogu_tester_profile_json(pl) ORDER BY pl.id)
                                  FROM players pl), '[]'::jsonb),

    'developerProfiles', coalesce((SELECT jsonb_agg(grogu_developer_profile_json(s) ORDER BY s.id)
                                     FROM studios s), '[]'::jsonb),

    'games', coalesce((SELECT jsonb_agg(grogu_game_json(g) ORDER BY g.updated_at DESC, g.id)
                         FROM games g), '[]'::jsonb),

    -- Drafts are visible only to the developer who owns them.
    'playtests', coalesce((SELECT jsonb_agg(grogu_playtest_view(p, p_viewer_id) ORDER BY p.created_at DESC, p.id)
                             FROM playtests p
                            WHERE p.game_id IS NOT NULL
                              AND (p.status <> 'draft' OR p.studio_id = v_studio_id)), '[]'::jsonb),

    'applications', coalesce((SELECT jsonb_agg(grogu_application_json(a) ORDER BY a.created_at DESC, a.id)
                                FROM applications a
                                JOIN playtests p ON p.id = a.playtest_id
                               WHERE a.player_id = v_player_id
                                  OR p.studio_id = v_studio_id), '[]'::jsonb),

    'feedback', coalesce((SELECT jsonb_agg(grogu_feedback_json(f) ORDER BY f.created_at DESC, f.id)
                            FROM feedback f
                            JOIN playtests p ON p.id = f.playtest_id
                           WHERE f.player_id = v_player_id
                              OR p.studio_id = v_studio_id), '[]'::jsonb),

    'testProgress', coalesce((SELECT jsonb_agg(grogu_progress_json(tp) ORDER BY tp.id)
                                FROM test_progress tp
                                JOIN playtests p ON p.id = tp.playtest_id
                               WHERE tp.tester_user_id = p_viewer_id
                                  OR p.studio_id = v_studio_id), '[]'::jsonb),

    'notifications', coalesce((SELECT jsonb_agg(grogu_notification_json(n) ORDER BY n.created_at DESC, n.id)
                                 FROM notifications n
                                WHERE n.user_id = p_viewer_id), '[]'::jsonb),

    -- Public totals for the marketing pages. These are counts over the whole
    -- platform, not over the caller's scoped collections, so an anonymous
    -- visitor still sees real numbers instead of zeroes.
    'stats', jsonb_build_object(
      'games',             (SELECT count(*) FROM games),
      'activePlaytests',   (SELECT count(*) FROM playtests
                             WHERE status IN ('recruiting', 'in-progress')),
      'testers',           (SELECT count(*) FROM users WHERE role = 'Player'),
      'feedbackSubmitted', (SELECT count(*) FROM feedback)
    )
  ) || grogu_bootstrap_extras(p_viewer_id, v_role) INTO v_result;

  RETURN v_result;
END;
$$;

COMMIT;
