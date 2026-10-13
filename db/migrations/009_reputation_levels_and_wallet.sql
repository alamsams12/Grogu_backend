-- 009_reputation_levels_and_wallet.sql
--
-- Phase 5: testers earn reputation for what they do, and level up.
--
--  * reputation_levels: a threshold table mapping reputation to a level.
--    Levels are derived on read, never stored, so changing a threshold
--    re-levels everyone at once.
--  * New earning rules in reputation_rules (from 008): one-time profile
--    bonuses (bio, personal details, profile picture), participation
--    (accepted, completed) and a bonus for a detailed review. Each is awarded
--    by grogu_reputation_award(), so each is once-only and lands in the
--    reputation history.
--  * Level-ups raise a notification. So does each profile bonus.
--  * players.upi_id: where a tester wants payouts sent. Format-checked only;
--    no payment method is integrated. The balance itself is the 008 ledger.
--    The UPI id is private: it is only returned to its owner.
--  * Profile pictures: avatarUrl now goes through grogu_asset_url(), the same
--    check posters use, so only Grogu uploads or https links are stored.
--
-- Additive and idempotent. Existing /api/v1 response shapes only gain fields.

BEGIN;

/* -------------------------------------------------------------------------- */
/*  Levels                                                                     */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS reputation_levels (
  level          integer PRIMARY KEY,
  min_reputation integer NOT NULL UNIQUE,
  title          text    NOT NULL,
  CONSTRAINT reputation_levels_min_check CHECK (min_reputation >= 0)
);

INSERT INTO reputation_levels (level, min_reputation, title) VALUES
  (1,   0, 'Newcomer'),
  (2,  25, 'Rookie'),
  (3,  60, 'Regular'),
  (4, 100, 'Skilled'),
  (5, 160, 'Veteran'),
  (6, 250, 'Expert'),
  (7, 400, 'Elite'),
  (8, 600, 'Legend')
ON CONFLICT (level) DO NOTHING;

CREATE OR REPLACE FUNCTION grogu_level_of(p_reputation integer) RETURNS integer
  LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT max(level) FROM reputation_levels
                    WHERE min_reputation <= coalesce(p_reputation, 0)), 1);
$$;

-- The level fields merged into a tester profile.
CREATE OR REPLACE FUNCTION grogu_level_json(p_reputation integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'level',       coalesce(cur.level, 1),
    'levelTitle',  coalesce(cur.title, 'Newcomer'),
    'levelFloor',  coalesce(cur.min_reputation, 0),
    -- null at the top level
    'nextLevelAt', (SELECT min(n.min_reputation) FROM reputation_levels n
                     WHERE n.min_reputation > coalesce(p_reputation, 0))
  )
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (
    SELECT * FROM reputation_levels l
     WHERE l.min_reputation <= coalesce(p_reputation, 0)
     ORDER BY l.min_reputation DESC
     LIMIT 1
  ) cur ON true;
$$;

/* -------------------------------------------------------------------------- */
/*  Earning rules                                                              */
/* -------------------------------------------------------------------------- */

INSERT INTO reputation_rules (reason, amount, variable, max_amount, category, label, description, position) VALUES
  ('profile-bio',          5,  false, NULL, 'profile',       'Bio added',
   'Write a bio of at least 40 characters about what you play and how you test.', 10),
  ('profile-details',      5,  false, NULL, 'profile',       'Personal details added',
   'Add your location, languages, platforms and favourite genres.', 11),
  ('profile-avatar',       10, false, NULL, 'profile',       'Profile picture added',
   'Upload a profile picture.', 12),
  ('application-accepted', 2,  false, NULL, 'participation', 'Accepted to a playtest',
   'A studio picked you for its playtest.', 20),
  ('test-completed',       10, false, NULL, 'participation', 'Playtest completed',
   'You finished the tasks and submitted feedback.', 21),
  ('review-detailed',      5,  false, NULL, 'review',        'Detailed review',
   'Your review had a summary of at least 120 characters and three or more highlights, pain points or bugs.', 30)
ON CONFLICT (reason) DO NOTHING;

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD  CONSTRAINT notifications_type_check
  CHECK (type IN ('application-accepted', 'application-rejected', 'application-received',
                  'feedback-received', 'playtest-published', 'test-reminder', 'system',
                  'feedback-approved', 'feedback-rejected', 'game-key-sent',
                  'reputation-earned', 'level-up'));

/* -------------------------------------------------------------------------- */
/*  Awarding, now with level-ups                                               */
/* -------------------------------------------------------------------------- */
-- Same contract as in 008. Additionally notifies the tester when a profile
-- bonus lands and when they cross into a new level. Backfills set the
-- transaction-local setting grogu.quiet = 'on' to award without notifying.

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
  v_after  integer;
  v_before integer;
  v_level  reputation_levels;
  v_quiet  boolean := coalesce(current_setting('grogu.quiet', true), '') = 'on';
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

  -- Increment, not recompute: under concurrent awards the row lock makes the
  -- second UPDATE add to the first one's result.
  UPDATE players SET reputation = reputation + v_amount
   WHERE user_id = p_user_id
  RETURNING reputation INTO v_after;
  v_before := v_after - v_amount;

  IF v_quiet THEN
    RETURN v_amount;
  END IF;

  IF r.category = 'profile' THEN
    PERFORM grogu_notify(
      p_user_id, 'reputation-earned',
      '+' || v_amount || ' reputation: ' || lower(r.label),
      'Thanks for completing your profile. Studios see it when you apply.',
      '/profile');
  END IF;

  IF grogu_level_of(v_after) > grogu_level_of(v_before) THEN
    SELECT * INTO v_level FROM reputation_levels WHERE level = grogu_level_of(v_after);
    PERFORM grogu_notify(
      p_user_id, 'level-up',
      'You reached level ' || v_level.level || ': ' || v_level.title,
      'Your reputation is now ' || v_after || '. Keep testing to reach the next level.',
      '/rewards');
  END IF;

  RETURN v_amount;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Profile bonuses                                                            */
/* -------------------------------------------------------------------------- */
-- Awards whichever one-time profile bonuses the tester now qualifies for.
-- Safe to call any number of times. Bonuses are never taken back if a field
-- is later cleared; the once-only constraint stops them being farmed.

CREATE OR REPLACE FUNCTION grogu_profile_check_bonuses(p_user_id integer) RETURNS integer
  LANGUAGE plpgsql AS $$
DECLARE
  u       users;
  pl      players;
  v_total integer := 0;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user_id AND role = 'Player';
  IF u.id IS NULL THEN
    RETURN 0;
  END IF;
  SELECT * INTO pl FROM players WHERE user_id = p_user_id;

  -- The signup default bio does not count.
  IF length(btrim(coalesce(u.bio, ''))) >= 40 AND u.bio <> 'New Grogu playtester.' THEN
    v_total := v_total + grogu_reputation_award(p_user_id, 'profile-bio', '');
  END IF;

  IF btrim(coalesce(u.location, '')) <> ''
     AND cardinality(coalesce(pl.languages, '{}')) > 0
     AND cardinality(grogu_split_csv(pl.platforms)) > 0
     AND cardinality(grogu_split_csv(pl.genres)) > 0 THEN
    v_total := v_total + grogu_reputation_award(p_user_id, 'profile-details', '');
  END IF;

  IF u.avatar_url IS NOT NULL THEN
    v_total := v_total + grogu_reputation_award(p_user_id, 'profile-avatar', '');
  END IF;

  RETURN v_total;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  UPI id                                                                     */
/* -------------------------------------------------------------------------- */

ALTER TABLE players ADD COLUMN IF NOT EXISTS upi_id text NOT NULL DEFAULT '';

-- Format only: handle@provider. Empty clears it.
CREATE OR REPLACE FUNCTION grogu_upi_id(p_value text) RETURNS text
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text := btrim(coalesce(p_value, ''));
BEGIN
  IF v = '' THEN
    RETURN '';
  END IF;
  IF v !~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,255}@[A-Za-z][A-Za-z0-9]{1,63}$' THEN
    RAISE EXCEPTION 'Enter a UPI ID like name@bank.' USING ERRCODE = 'GR005';
  END IF;
  RETURN v;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Profile save                                                               */
/* -------------------------------------------------------------------------- */
-- 005's partial-update version, plus: avatarUrl is validated like a poster,
-- testers can set upiId, and profile bonuses are checked after every save.

CREATE OR REPLACE FUNCTION grogu_profile_save(p_user_id integer, p_input jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  u      users;
  v_role text;
BEGIN
  SELECT grogu_role_to_api(role) INTO v_role FROM users WHERE id = p_user_id;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Not signed in.' USING ERRCODE = 'GR004';
  END IF;

  IF p_input ? 'name' AND trim(coalesce(p_input ->> 'name', '')) = '' THEN
    RAISE EXCEPTION 'Enter your name.' USING ERRCODE = 'GR005';
  END IF;

  IF p_input ? 'weeklyAvailabilityHours' THEN
    IF (p_input ->> 'weeklyAvailabilityHours') !~ '^\d+$'
       OR (p_input ->> 'weeklyAvailabilityHours')::int NOT BETWEEN 0 AND 168 THEN
      RAISE EXCEPTION 'Weekly availability must be between 0 and 168 hours.'
        USING ERRCODE = 'GR005';
    END IF;
  END IF;

  IF p_input ? 'foundedYear' THEN
    IF (p_input ->> 'foundedYear') !~ '^\d{4}$'
       OR (p_input ->> 'foundedYear')::int NOT BETWEEN 1950 AND extract(year FROM now())::int THEN
      RAISE EXCEPTION 'Enter a founding year between 1950 and %.',
        extract(year FROM now())::int USING ERRCODE = 'GR005';
    END IF;
  END IF;

  UPDATE users SET
    name       = CASE WHEN p_input ? 'name'
                      THEN trim(p_input ->> 'name') ELSE name END,
    location   = CASE WHEN p_input ? 'location'
                      THEN coalesce(p_input ->> 'location', '') ELSE location END,
    bio        = CASE WHEN p_input ? 'bio'
                      THEN coalesce(p_input ->> 'bio', '') ELSE bio END,
    -- Present-but-empty clears the avatar; absent leaves it.
    avatar_url = CASE WHEN p_input ? 'avatarUrl'
                      THEN grogu_asset_url(p_input ->> 'avatarUrl')
                      ELSE avatar_url END
   WHERE id = p_user_id
  RETURNING * INTO u;

  IF v_role = 'tester' THEN
    PERFORM grogu_player_id(p_user_id);

    UPDATE players SET
      experience = CASE WHEN p_input ? 'experienceLevel'
                        THEN p_input ->> 'experienceLevel' ELSE experience END,
      platforms  = CASE WHEN p_input ? 'platforms'
                        THEN array_to_string(grogu_jsonb_text_array(p_input -> 'platforms'), ',')
                        ELSE platforms END,
      genres     = CASE WHEN p_input ? 'preferredGenres'
                        THEN array_to_string(grogu_jsonb_text_array(p_input -> 'preferredGenres'), ',')
                        ELSE genres END,
      languages  = CASE WHEN p_input ? 'languages'
                        THEN grogu_jsonb_text_array(p_input -> 'languages')
                        ELSE languages END,
      weekly_availability_hours = CASE WHEN p_input ? 'weeklyAvailabilityHours'
                        THEN (p_input ->> 'weeklyAvailabilityHours')::int
                        ELSE weekly_availability_hours END,
      upi_id     = CASE WHEN p_input ? 'upiId'
                        THEN grogu_upi_id(p_input ->> 'upiId') ELSE upi_id END
     WHERE user_id = p_user_id;

    PERFORM grogu_profile_check_bonuses(p_user_id);

  ELSIF v_role = 'developer' THEN
    PERFORM grogu_studio_id(p_user_id);

    IF p_input ? 'studioName' AND trim(coalesce(p_input ->> 'studioName', '')) = '' THEN
      RAISE EXCEPTION 'Enter a studio name.' USING ERRCODE = 'GR005';
    END IF;

    UPDATE studios SET
      name         = CASE WHEN p_input ? 'studioName'
                          THEN trim(p_input ->> 'studioName') ELSE name END,
      website      = CASE WHEN p_input ? 'website'
                          THEN nullif(trim(coalesce(p_input ->> 'website', '')), '')
                          ELSE website END,
      studio_size  = CASE WHEN p_input ? 'studioSize'
                          THEN p_input ->> 'studioSize' ELSE studio_size END,
      founded_year = CASE WHEN p_input ? 'foundedYear'
                          THEN (p_input ->> 'foundedYear')::int ELSE founded_year END
     WHERE user_id = p_user_id;
  END IF;

  RETURN grogu_user_json(u, p_user_id);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Participation                                                              */
/* -------------------------------------------------------------------------- */
-- 003's version plus the "accepted" award.

CREATE OR REPLACE FUNCTION grogu_application_decide(
  p_user_id integer, p_application_id integer, p_decision text, p_note text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  a          applications;
  p          playtests;
  v_studio   integer;
  v_tester   integer;
  v_accepted integer;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  v_studio := grogu_studio_id(p_user_id);

  IF p_decision NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION 'Decision must be accepted or rejected.' USING ERRCODE = 'GR005';
  END IF;

  SELECT a2.* INTO a
    FROM applications a2
    JOIN playtests p2 ON p2.id = a2.playtest_id
   WHERE a2.id = p_application_id AND p2.studio_id = v_studio;
  IF a.id IS NULL THEN
    RAISE EXCEPTION 'Application not found.' USING ERRCODE = 'GR001';
  END IF;
  IF a.status = 'Withdrawn' THEN
    RAISE EXCEPTION 'That application was withdrawn.' USING ERRCODE = 'GR003';
  END IF;

  SELECT * INTO p FROM playtests WHERE id = a.playtest_id;
  SELECT pl.user_id INTO v_tester FROM players pl WHERE pl.id = a.player_id;

  -- The roster cap is the developer's own `maxTesters`; the mock never enforced
  -- it because nothing could oversubscribe a local store.
  IF p_decision = 'accepted' AND a.status <> 'Selected' THEN
    SELECT count(*) INTO v_accepted FROM applications
     WHERE playtest_id = p.id AND status IN ('Selected', 'Completed');
    IF v_accepted >= p.max_testers THEN
      RAISE EXCEPTION 'This playtest is already full (% of % testers).', v_accepted, p.max_testers
        USING ERRCODE = 'GR003';
    END IF;
  END IF;

  UPDATE applications SET
    status        = grogu_appstatus_to_db(p_decision),
    decided_at    = now(),
    decision_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), decision_note)
   WHERE id = a.id
  RETURNING * INTO a;

  IF p_decision = 'accepted' THEN
    INSERT INTO test_progress (playtest_id, tester_user_id)
    VALUES (p.id, v_tester)
    ON CONFLICT (playtest_id, tester_user_id) DO NOTHING;

    PERFORM grogu_notify(
      v_tester, 'application-accepted',
      'You''re in: ' || coalesce(p.title, p.game_name),
      'Your application was accepted. Open the test workspace to get started.',
      '/tests/' || p.id);

    PERFORM grogu_reputation_award(v_tester, 'application-accepted', p.id::text, NULL, '', p.id, NULL, p_user_id);
  ELSE
    PERFORM grogu_notify(
      v_tester, 'application-rejected',
      'Update on ' || coalesce(p.title, p.game_name),
      coalesce(nullif(trim(coalesce(p_note, '')), ''),
               'Your application wasn''t selected this time. Keep an eye on Discover for more playtests.'),
      '/discover');
  END IF;

  RETURN grogu_application_json(a);
END;
$$;

-- 007's version plus the "completed" and "detailed review" awards.
CREATE OR REPLACE FUNCTION grogu_feedback_submit(
  p_user_id integer, p_playtest_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  f          feedback;
  tp         test_progress;
  p          playtests;
  v_player   integer;
  v_dev      integer;
  v_ratings  jsonb := coalesce(p_input -> 'ratings', '{}'::jsonb);
  v_avg      integer;
BEGIN
  PERFORM grogu_require_accepted(p_user_id, p_playtest_id);
  v_player := grogu_player_id(p_user_id);

  IF EXISTS (SELECT 1 FROM feedback WHERE playtest_id = p_playtest_id AND player_id = v_player) THEN
    RAISE EXCEPTION 'You have already submitted feedback for this playtest.' USING ERRCODE = 'GR003';
  END IF;

  FOREACH v_avg IN ARRAY ARRAY[
    coalesce((v_ratings ->> 'fun')::int, 0),
    coalesce((v_ratings ->> 'difficulty')::int, 0),
    coalesce((v_ratings ->> 'clarity')::int, 0),
    coalesce((v_ratings ->> 'performance')::int, 0),
    coalesce((v_ratings ->> 'polish')::int, 0)
  ] LOOP
    IF v_avg < 1 OR v_avg > 5 THEN
      RAISE EXCEPTION 'Every rating must be between 1 and 5.' USING ERRCODE = 'GR005';
    END IF;
  END LOOP;

  SELECT * INTO p FROM playtests WHERE id = p_playtest_id;

  INSERT INTO feedback (
    playtest_id, player_id,
    rating_fun, rating_difficulty, rating_clarity, rating_performance, rating_polish,
    sentiment, summary, highlights, pain_points, bugs, answers, would_recommend, hours_played, media,
    -- legacy columns, kept populated so `/api/feedback/*` still works
    rating, comment
  ) VALUES (
    p_playtest_id, v_player,
    (v_ratings ->> 'fun')::int,
    (v_ratings ->> 'difficulty')::int,
    (v_ratings ->> 'clarity')::int,
    (v_ratings ->> 'performance')::int,
    (v_ratings ->> 'polish')::int,
    coalesce(p_input ->> 'sentiment', 'neutral'),
    coalesce(p_input ->> 'summary', ''),
    grogu_jsonb_text_array(p_input -> 'highlights'),
    grogu_jsonb_text_array(p_input -> 'painPoints'),
    grogu_jsonb_text_array(p_input -> 'bugs'),
    coalesce(p_input -> 'answers', '[]'::jsonb),
    coalesce((p_input ->> 'wouldRecommend')::boolean, true),
    coalesce((p_input ->> 'hoursPlayed')::numeric, 0),
    grogu_media_json(p_input -> 'media'),
    greatest(1, least(5, round((
      coalesce((v_ratings ->> 'fun')::int, 3) +
      coalesce((v_ratings ->> 'difficulty')::int, 3) +
      coalesce((v_ratings ->> 'clarity')::int, 3) +
      coalesce((v_ratings ->> 'performance')::int, 3) +
      coalesce((v_ratings ->> 'polish')::int, 3)
    ) / 5.0)::int)),
    coalesce(p_input ->> 'summary', '')
  )
  RETURNING * INTO f;

  tp := grogu_progress_row(p_playtest_id, p_user_id);
  UPDATE test_progress SET
    stage        = 'completed',
    feedback_id  = f.id,
    completed_at = now(),
    started_at   = coalesce(started_at, now())
   WHERE id = tp.id
  RETURNING * INTO tp;

  -- An accepted tester who has finished is marked Completed, which is what the
  -- legacy application status vocabulary already meant by it.
  UPDATE applications SET status = 'Completed'
   WHERE playtest_id = p_playtest_id AND player_id = v_player AND status = 'Selected';

  PERFORM grogu_reputation_award(p_user_id, 'test-completed', p_playtest_id::text, NULL, '', p_playtest_id, NULL, NULL);
  IF length(btrim(f.summary)) >= 120
     AND cardinality(f.highlights) + cardinality(f.pain_points) + cardinality(f.bugs) >= 3 THEN
    PERFORM grogu_reputation_award(p_user_id, 'review-detailed', f.id::text, NULL, '', p_playtest_id, f.id, NULL);
  END IF;

  SELECT s.user_id INTO v_dev FROM studios s WHERE s.id = p.studio_id;
  PERFORM grogu_notify(
    v_dev, 'feedback-received',
    'New feedback for ' || coalesce(p.title, p.game_name),
    'A tester submitted feedback (' || coalesce(p_input ->> 'hoursPlayed', '0') || 'h played).',
    '/developer/playtests/' || p.id);

  RETURN jsonb_build_object(
    'feedback', grogu_feedback_json(f),
    'progress', grogu_progress_json(tp)
  );
END;
$$;

/* -------------------------------------------------------------------------- */
/*  JSON                                                                       */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_tester_profile_json(pl players) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'userId',                  pl.user_id::text,
    'experienceLevel',         coalesce(pl.experience, 'casual'),
    'preferredGenres',         to_jsonb(grogu_split_csv(pl.genres)),
    'platforms',               to_jsonb(grogu_split_csv(pl.platforms)),
    'languages',               to_jsonb(pl.languages),
    'weeklyAvailabilityHours', pl.weekly_availability_hours,
    'reputation',              pl.reputation,
    'completedPlaytests',      (SELECT count(*) FROM test_progress tp
                                 WHERE tp.tester_user_id = pl.user_id AND tp.stage = 'completed'),
    'averageFeedbackRating',   coalesce((
                                 SELECT round(avg((f.rating_fun + f.rating_difficulty + f.rating_clarity
                                                 + f.rating_performance + f.rating_polish) / 5.0), 2)
                                   FROM feedback f WHERE f.player_id = pl.id), 0),
    'badges',                  to_jsonb(pl.badges)
  ) || grogu_level_json(pl.reputation);
$$;

CREATE OR REPLACE FUNCTION grogu_reputation_event_json(e reputation_events) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',         e.id::text,
    'userId',     e.user_id::text,
    'reason',     e.reason,
    'label',      (SELECT r.label FROM reputation_rules r WHERE r.reason = e.reason),
    'amount',     e.amount,
    'playtestId', e.playtest_id::text,
    'feedbackId', e.feedback_id::text,
    'note',       e.note,
    'createdAt',  grogu_iso(e.created_at)
  );
$$;

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

    -- Only the owner sees their UPI id.
    'wallet', CASE WHEN p_role = 'tester' THEN jsonb_build_object(
      'balance', (SELECT coalesce(sum(l.amount), 0) FROM ledger_entries l WHERE l.user_id = p_viewer_id),
      'upiId',   coalesce((SELECT pl.upi_id FROM players pl WHERE pl.user_id = p_viewer_id), ''))
      ELSE NULL END,

    -- The viewer's own reputation history.
    'reputationEvents', coalesce((SELECT jsonb_agg(grogu_reputation_event_json(e) ORDER BY e.created_at DESC, e.id DESC)
                                    FROM reputation_events e WHERE e.user_id = p_viewer_id), '[]'::jsonb),

    -- Public: how reputation is earned and what each level needs.
    'reputationRules', coalesce((SELECT jsonb_agg(jsonb_build_object(
                                          'reason',      r.reason,
                                          'amount',      r.amount,
                                          'variable',    r.variable,
                                          'maxAmount',   r.max_amount,
                                          'category',    r.category,
                                          'label',       r.label,
                                          'description', r.description) ORDER BY r.position, r.reason)
                                   FROM reputation_rules r WHERE r.active), '[]'::jsonb),

    'reputationLevels', coalesce((SELECT jsonb_agg(jsonb_build_object(
                                           'level',         l.level,
                                           'title',         l.title,
                                           'minReputation', l.min_reputation) ORDER BY l.level)
                                    FROM reputation_levels l), '[]'::jsonb)
  );
$$;

/* -------------------------------------------------------------------------- */
/*  Backfill                                                                   */
/* -------------------------------------------------------------------------- */
-- Existing testers with a complete profile get their profile bonuses now, so
-- the rule applies the same way to everyone. No notifications for this.

DO $$
BEGIN
  PERFORM set_config('grogu.quiet', 'on', true);
  PERFORM grogu_profile_check_bonuses(pl.user_id) FROM players pl;
  PERFORM set_config('grogu.quiet', 'off', true);
END
$$;

COMMIT;
