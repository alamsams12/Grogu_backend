-- 014_reward_pool_payments.sql
--
-- Studios fund a playtest's cash reward pool through Razorpay, and cash rewards
-- on approved reviews are paid out of that pool.
--
--  * payment_orders: one row per Razorpay order. The API creates the order with
--    Razorpay (the key secret never leaves the server), then records it here.
--    An order is marked paid exactly once, either by the browser's verified
--    checkout callback or by Razorpay's webhook, whichever arrives first. The
--    amount credited is the amount stored when the order was created, never a
--    value sent by the browser.
--  * reward_pool_entries: an append-only ledger per playtest. Funding is
--    positive, cash paid to a tester is negative. A playtest's pool balance is
--    the sum of its entries.
--  * grogu_feedback_review: approving a review with cash now requires the pool
--    to cover it. The playtest row is locked while the balance is checked, so
--    two approvals can never spend the same rupees twice.
--
-- Amounts are whole Indian rupees in the database (as in ledger_entries);
-- Razorpay is sent paise (rupees x 100).
--
-- Additive and idempotent.

BEGIN;

/* -------------------------------------------------------------------------- */
/*  Tables                                                                     */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS payment_orders (
  id                  serial PRIMARY KEY,
  user_id             integer     NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  playtest_id         integer     NOT NULL REFERENCES playtests(id) ON DELETE RESTRICT,
  amount              integer     NOT NULL,
  currency            varchar(3)  NOT NULL DEFAULT 'INR',
  status              varchar(16) NOT NULL DEFAULT 'created',
  razorpay_order_id   varchar(64),
  razorpay_payment_id varchar(64),
  failure_reason      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  paid_at             timestamptz,
  CONSTRAINT payment_orders_amount_check CHECK (amount > 0),
  CONSTRAINT payment_orders_status_check CHECK (status IN ('created', 'paid', 'failed'))
);

CREATE UNIQUE INDEX IF NOT EXISTS payment_orders_razorpay_order_key   ON payment_orders (razorpay_order_id)   WHERE razorpay_order_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payment_orders_razorpay_payment_key ON payment_orders (razorpay_payment_id) WHERE razorpay_payment_id IS NOT NULL;
CREATE INDEX        IF NOT EXISTS payment_orders_playtest_idx         ON payment_orders (playtest_id, created_at DESC);

CREATE TABLE IF NOT EXISTS reward_pool_entries (
  id               serial PRIMARY KEY,
  playtest_id      integer     NOT NULL REFERENCES playtests(id) ON DELETE RESTRICT,
  amount           integer     NOT NULL,
  kind             varchar(16) NOT NULL,
  payment_order_id integer     REFERENCES payment_orders(id) ON DELETE RESTRICT,
  feedback_id      integer     REFERENCES feedback(id) ON DELETE SET NULL,
  created_by       integer     REFERENCES users(id) ON DELETE SET NULL,
  note             text        NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reward_pool_entries_kind_check   CHECK (kind IN ('funding', 'review-reward', 'refund', 'adjustment')),
  CONSTRAINT reward_pool_entries_amount_check CHECK (amount <> 0),
  CONSTRAINT reward_pool_entries_sign_check   CHECK (
    (kind = 'funding' AND amount > 0) OR (kind IN ('review-reward', 'refund') AND amount < 0) OR kind = 'adjustment')
);

CREATE INDEX        IF NOT EXISTS reward_pool_entries_playtest_idx ON reward_pool_entries (playtest_id, created_at DESC);
-- One credit per paid order and one debit per approved review.
CREATE UNIQUE INDEX IF NOT EXISTS reward_pool_entries_order_key    ON reward_pool_entries (payment_order_id) WHERE kind = 'funding';
CREATE UNIQUE INDEX IF NOT EXISTS reward_pool_entries_feedback_key ON reward_pool_entries (feedback_id)      WHERE kind = 'review-reward';

CREATE OR REPLACE FUNCTION grogu_reward_pool_guard() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Reward pool entries cannot be deleted. Write a new entry instead.' USING ERRCODE = 'GR003';
  END IF;
  IF NEW.amount <> OLD.amount OR NEW.playtest_id <> OLD.playtest_id OR NEW.kind <> OLD.kind THEN
    RAISE EXCEPTION 'Reward pool entries cannot be changed. Write a new entry instead.' USING ERRCODE = 'GR003';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reward_pool_entries_guard ON reward_pool_entries;
CREATE TRIGGER reward_pool_entries_guard BEFORE UPDATE OR DELETE ON reward_pool_entries
  FOR EACH ROW EXECUTE FUNCTION grogu_reward_pool_guard();

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD  CONSTRAINT notifications_type_check
  CHECK (type IN ('application-accepted', 'application-rejected', 'application-received',
                  'feedback-received', 'playtest-published', 'test-reminder', 'system',
                  'feedback-approved', 'feedback-rejected', 'game-key-sent',
                  'reputation-earned', 'level-up', 'playtest-invite',
                  'bug-reported', 'bug-status', 'review-received', 'review-reply',
                  'reward-pool-funded'));

/* -------------------------------------------------------------------------- */
/*  JSON                                                                       */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_reward_pool_json(p_playtest_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'funded',  coalesce(sum(e.amount) FILTER (WHERE e.amount > 0), 0),
    'paidOut', coalesce(-sum(e.amount) FILTER (WHERE e.kind = 'review-reward'), 0),
    'balance', coalesce(sum(e.amount), 0)
  ) FROM reward_pool_entries e WHERE e.playtest_id = p_playtest_id;
$$;

CREATE OR REPLACE FUNCTION grogu_payment_order_json(o payment_orders) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',              o.id::text,
    'playtestId',      o.playtest_id::text,
    'amount',          o.amount,
    'currency',        o.currency,
    'status',          o.status,
    'razorpayOrderId', o.razorpay_order_id,
    'createdAt',       grogu_iso(o.created_at),
    'paidAt',          grogu_iso(o.paid_at)
  );
$$;

CREATE OR REPLACE FUNCTION grogu_reward_pool_entry_json(e reward_pool_entries) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',         e.id::text,
    'playtestId', e.playtest_id::text,
    'amount',     e.amount,
    'kind',       e.kind,
    'feedbackId', e.feedback_id::text,
    'note',       e.note,
    'createdAt',  grogu_iso(e.created_at)
  );
$$;

-- The playtest document: as in 007, plus the pool. The owning studio sees the
-- figures; everyone else only learns whether the listed cash reward is backed
-- by funds already paid in.
CREATE OR REPLACE FUNCTION grogu_playtest_view(p playtests, p_viewer_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT grogu_playtest_json(p)
    || jsonb_build_object(
         'cashFunded', coalesce(p.cash_reward, 0) > 0
                       AND (grogu_reward_pool_json(p.id) ->> 'balance')::int >= p.cash_reward)
    || CASE
    WHEN p_viewer_id IS NOT NULL AND EXISTS (SELECT 1 FROM studios s
                                              WHERE s.id = p.studio_id AND s.user_id = p_viewer_id)
    THEN jsonb_build_object(
           'buildUrl',            p.build_url,
           'installInstructions', p.install_instructions,
           'accessKey',           p.access_key,
           'rewardPool',          grogu_reward_pool_json(p.id))
    WHEN p_viewer_id IS NOT NULL AND EXISTS (SELECT 1 FROM applications a
                                               JOIN players pl ON pl.id = a.player_id
                                              WHERE a.playtest_id = p.id
                                                AND pl.user_id = p_viewer_id
                                                AND a.status IN ('Selected', 'Completed'))
    THEN jsonb_build_object(
           'buildUrl',            p.build_url,
           'installInstructions', p.install_instructions,
           'accessKey',           p.access_key)
    ELSE '{}'::jsonb
  END;
$$;

/* -------------------------------------------------------------------------- */
/*  Orders                                                                     */
/* -------------------------------------------------------------------------- */
-- Step 1, before calling Razorpay: checks the studio owns the playtest and the
-- amount is allowed, and records a 'created' order. Returns the row id the API
-- uses as Razorpay's `receipt`.

CREATE OR REPLACE FUNCTION grogu_payment_order_prepare(p_user_id integer, p_input jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  p        playtests;
  o        payment_orders;
  v_amount integer;
  v_pt     integer;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  BEGIN
    v_pt := nullif(p_input ->> 'playtestId', '')::int;
  EXCEPTION WHEN invalid_text_representation THEN
    v_pt := NULL;
  END;

  SELECT p2.* INTO p FROM playtests p2 JOIN studios s ON s.id = p2.studio_id
   WHERE p2.id = v_pt AND s.user_id = p_user_id;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
  END IF;
  IF p.status IN ('closed', 'archived') THEN
    RAISE EXCEPTION 'This playtest is %, so its reward pool can''t be topped up.', p.status USING ERRCODE = 'GR003';
  END IF;

  v_amount := grogu_int_field(p_input, 'amount', 0, 500000, 'The amount');
  IF v_amount < 100 THEN
    RAISE EXCEPTION 'Add at least ₹100.' USING ERRCODE = 'GR005';
  END IF;

  -- Abandoned checkouts leave 'created' rows; cap them so a loop can't flood Razorpay.
  IF (SELECT count(*) FROM payment_orders
       WHERE user_id = p_user_id AND created_at > now() - interval '1 hour') >= 20 THEN
    RAISE EXCEPTION 'Too many payment attempts. Please wait a while and try again.' USING ERRCODE = 'GR003';
  END IF;

  INSERT INTO payment_orders (user_id, playtest_id, amount)
  VALUES (p_user_id, p.id, v_amount)
  RETURNING * INTO o;

  RETURN jsonb_build_object(
    'id', o.id::text,
    'amount', o.amount,
    'amountPaise', o.amount * 100,
    'currency', o.currency,
    'receipt', 'grogu-po-' || o.id,
    'playtestId', p.id::text,
    'playtestTitle', coalesce(p.title, p.game_name));
END;
$$;

-- Step 2, after Razorpay created the order: links it to our row.
CREATE OR REPLACE FUNCTION grogu_payment_order_attach(
  p_user_id integer, p_order_id integer, p_razorpay_order_id text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o payment_orders;
BEGIN
  UPDATE payment_orders SET razorpay_order_id = p_razorpay_order_id
   WHERE id = p_order_id AND user_id = p_user_id AND status = 'created' AND razorpay_order_id IS NULL
  RETURNING * INTO o;
  IF o.id IS NULL THEN
    RAISE EXCEPTION 'Payment order not found.' USING ERRCODE = 'GR001';
  END IF;
  RETURN grogu_payment_order_json(o);
END;
$$;

-- Razorpay refused to create the order (or could not be reached).
CREATE OR REPLACE FUNCTION grogu_payment_order_fail(p_order_id integer, p_reason text) RETURNS void
  LANGUAGE sql AS $$
  UPDATE payment_orders SET status = 'failed', failure_reason = left(coalesce(p_reason, ''), 500)
   WHERE id = p_order_id AND status = 'created';
$$;

-- A failed payment attempt reported by the webhook. The order stays payable:
-- Razorpay lets the customer retry the same order, so this only notes why.
CREATE OR REPLACE FUNCTION grogu_payment_attempt_failed(p_razorpay_order_id text, p_reason text) RETURNS void
  LANGUAGE sql AS $$
  UPDATE payment_orders SET failure_reason = left(coalesce(p_reason, ''), 500)
   WHERE razorpay_order_id = p_razorpay_order_id AND status = 'created';
$$;

/* -------------------------------------------------------------------------- */
/*  Capture                                                                    */
/* -------------------------------------------------------------------------- */
-- Marks an order paid and credits the pool. Called only after the API has
-- verified Razorpay's signature (checkout callback or webhook).
--
--  * p_user_id: the signed-in studio for the checkout callback, which must own
--    the order; NULL for the webhook, which is authenticated by its signature.
--  * p_amount_paise: the amount Razorpay reports (webhook); it must match the
--    stored order. NULL from the checkout callback, whose signature already
--    binds the payment to this order and therefore to the stored amount.
--
-- Idempotent: a second call for a paid order returns it unchanged. The order
-- row is locked, so the callback and the webhook arriving together credit once.

CREATE OR REPLACE FUNCTION grogu_payment_capture(
  p_user_id integer, p_razorpay_order_id text, p_razorpay_payment_id text, p_amount_paise bigint
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  o payment_orders;
  p playtests;
BEGIN
  SELECT * INTO o FROM payment_orders WHERE razorpay_order_id = p_razorpay_order_id FOR UPDATE;
  IF o.id IS NULL OR (p_user_id IS NOT NULL AND o.user_id <> p_user_id) THEN
    RAISE EXCEPTION 'Payment order not found.' USING ERRCODE = 'GR001';
  END IF;

  IF o.status = 'paid' THEN
    RETURN jsonb_build_object('order', grogu_payment_order_json(o),
                              'rewardPool', grogu_reward_pool_json(o.playtest_id),
                              'alreadyPaid', true);
  END IF;

  IF p_amount_paise IS NOT NULL AND p_amount_paise <> o.amount::bigint * 100 THEN
    RAISE EXCEPTION 'Paid amount does not match the order.' USING ERRCODE = 'GR005';
  END IF;
  IF coalesce(btrim(p_razorpay_payment_id), '') = '' THEN
    RAISE EXCEPTION 'Missing payment id.' USING ERRCODE = 'GR005';
  END IF;

  -- A capture can arrive after the order was marked failed (Razorpay retried).
  UPDATE payment_orders SET status = 'paid', razorpay_payment_id = p_razorpay_payment_id,
                            paid_at = now(), failure_reason = NULL
   WHERE id = o.id
  RETURNING * INTO o;

  SELECT * INTO p FROM playtests WHERE id = o.playtest_id;

  INSERT INTO reward_pool_entries (playtest_id, amount, kind, payment_order_id, created_by, note)
  VALUES (o.playtest_id, o.amount, 'funding', o.id, o.user_id,
          'Razorpay payment ' || p_razorpay_payment_id);

  PERFORM grogu_notify(
    o.user_id, 'reward-pool-funded',
    grogu_rupees(o.amount) || ' added to the ' || coalesce(p.title, p.game_name) || ' reward pool',
    'Pool balance is now ' || grogu_rupees((grogu_reward_pool_json(o.playtest_id) ->> 'balance')::int) || '.',
    '/developer/playtests/' || o.playtest_id);

  RETURN jsonb_build_object('order', grogu_payment_order_json(o),
                            'rewardPool', grogu_reward_pool_json(o.playtest_id),
                            'alreadyPaid', false);
END;
$$;

-- The studio's pool history for one playtest: entries and orders.
CREATE OR REPLACE FUNCTION grogu_reward_pool_view(p_user_id integer, p_playtest_id integer) RETURNS jsonb
  LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  IF NOT EXISTS (SELECT 1 FROM playtests p JOIN studios s ON s.id = p.studio_id
                  WHERE p.id = p_playtest_id AND s.user_id = p_user_id) THEN
    RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
  END IF;

  RETURN jsonb_build_object(
    'playtestId', p_playtest_id::text,
    'pool',       grogu_reward_pool_json(p_playtest_id),
    'entries',    coalesce((SELECT jsonb_agg(grogu_reward_pool_entry_json(e) ORDER BY e.created_at DESC, e.id DESC)
                              FROM reward_pool_entries e WHERE e.playtest_id = p_playtest_id), '[]'::jsonb),
    'orders',     coalesce((SELECT jsonb_agg(grogu_payment_order_json(o) ORDER BY o.created_at DESC, o.id DESC)
                              FROM payment_orders o
                             WHERE o.playtest_id = p_playtest_id AND o.razorpay_order_id IS NOT NULL), '[]'::jsonb));
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Review approval pays cash from the pool                                    */
/* -------------------------------------------------------------------------- */
-- Same contract as 008. When cashAmount > 0 the playtest row is locked and the
-- pool must cover the amount; the debit and the tester's credit are written in
-- the same transaction as the approval.

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
  v_balance  integer;
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

  -- Check the pool before anything is written. Locking the playtest row
  -- serialises cash approvals within one playtest, so the balance read here
  -- is still true when the debit below is written.
  IF v_cash > 0 THEN
    PERFORM 1 FROM playtests WHERE id = p.id FOR UPDATE;
    v_balance := (grogu_reward_pool_json(p.id) ->> 'balance')::int;
    IF v_balance < v_cash THEN
      RAISE EXCEPTION 'The reward pool has % left, which doesn''t cover %. Add funds to the pool, or lower the cash reward.',
        grogu_rupees(v_balance), grogu_rupees(v_cash) USING ERRCODE = 'GR003';
    END IF;
  END IF;

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
    INSERT INTO reward_pool_entries (playtest_id, amount, kind, feedback_id, created_by, note)
    VALUES (p.id, -v_cash, 'review-reward', f.id, p_user_id, 'Reward for a review of ' || v_title);

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

COMMIT;
