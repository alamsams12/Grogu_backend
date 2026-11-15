-- Reward pools: Razorpay orders, idempotent capture, pool-backed cash rewards.
-- Rolls back.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

CREATE FUNCTION pg_temp.balance(pt integer) RETURNS integer
  LANGUAGE sql AS $$ SELECT (grogu_reward_pool_json(pt) ->> 'balance')::int $$;

DO $t$
DECLARE
  dev_id    integer;
  other_dev integer;
  t1        integer;
  t2        integer;
  game_id   integer;
  pt_id     integer;
  ord       jsonb;
  ord_id    integer;
  res       jsonb;
  fb1       integer;
  fb2       integer;
  doc       jsonb;
  ratings   jsonb := '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}';
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Pay Dev","email":"paydev@test.invalid","password":"secret123","studioName":"Pay Studio"}') ->> 'id')::int;
  other_dev := (grogu_signup('{"role":"developer","name":"Pay Other","email":"payother@test.invalid","password":"secret123","studioName":"Other"}') ->> 'id')::int;
  t1 := (grogu_signup('{"role":"tester","name":"Pay One","email":"pay1@test.invalid","password":"secret123"}') ->> 'id')::int;
  t2 := (grogu_signup('{"role":"tester","name":"Pay Two","email":"pay2@test.invalid","password":"secret123"}') ->> 'id')::int;

  game_id := (grogu_game_save(dev_id, NULL, '{"title":"Pay Game"}') ->> 'id')::int;
  pt_id := (grogu_playtest_save(dev_id, NULL, jsonb_build_object('gameId', game_id, 'title', 'Pay playtest',
              'maxTesters', 5, 'publish', true, 'cashReward', 300,
              'tasks', '[{"title":"Play","type":"objective","required":true}]'::jsonb)) ->> 'id')::int;

  /* ---- Pool visibility ---------------------------------------------- */
  doc := (SELECT p FROM jsonb_array_elements(grogu_bootstrap(dev_id) -> 'playtests') p WHERE p ->> 'id' = pt_id::text);
  PERFORM pg_temp.assert((doc -> 'rewardPool' ->> 'balance')::int = 0, 'the owner sees an empty pool');
  PERFORM pg_temp.assert(NOT (doc ->> 'cashFunded')::boolean, 'an empty pool does not back the cash reward');
  doc := (SELECT p FROM jsonb_array_elements(grogu_bootstrap(t1) -> 'playtests') p WHERE p ->> 'id' = pt_id::text);
  PERFORM pg_temp.assert(NOT doc ? 'rewardPool', 'a tester does not see the pool figures');

  /* ---- Preparing an order ------------------------------------------- */
  BEGIN
    PERFORM grogu_payment_order_prepare(other_dev, jsonb_build_object('playtestId', pt_id::text, 'amount', 500));
    RAISE EXCEPTION 'FAIL: another studio funded the playtest';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_payment_order_prepare(t1, jsonb_build_object('playtestId', pt_id::text, 'amount', 500));
    RAISE EXCEPTION 'FAIL: a tester funded the playtest';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_payment_order_prepare(dev_id, jsonb_build_object('playtestId', pt_id::text, 'amount', 99));
    RAISE EXCEPTION 'FAIL: less than the minimum was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_payment_order_prepare(dev_id, jsonb_build_object('playtestId', pt_id::text, 'amount', 150.5));
    RAISE EXCEPTION 'FAIL: a fractional amount was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_payment_order_prepare(dev_id, '{"playtestId":"abc","amount":500}');
    RAISE EXCEPTION 'FAIL: a malformed playtest id was accepted';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;

  ord := grogu_payment_order_prepare(dev_id, jsonb_build_object('playtestId', pt_id::text, 'amount', 500));
  ord_id := (ord ->> 'id')::int;
  PERFORM pg_temp.assert((ord ->> 'amountPaise')::int = 50000, 'Razorpay is sent paise');
  PERFORM pg_temp.assert(ord ->> 'receipt' = 'grogu-po-' || ord_id, 'the receipt names our order');

  BEGIN
    PERFORM grogu_payment_order_attach(other_dev, ord_id, 'order_X');
    RAISE EXCEPTION 'FAIL: another studio attached an order';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  res := grogu_payment_order_attach(dev_id, ord_id, 'order_A');
  PERFORM pg_temp.assert(res ->> 'status' = 'created' AND res ->> 'razorpayOrderId' = 'order_A', 'the order is attached');
  BEGIN
    PERFORM grogu_payment_order_attach(dev_id, ord_id, 'order_B');
    RAISE EXCEPTION 'FAIL: an order was attached twice';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;

  /* ---- Capture ------------------------------------------------------ */
  BEGIN
    PERFORM grogu_payment_capture(other_dev, 'order_A', 'pay_A', NULL);
    RAISE EXCEPTION 'FAIL: another studio captured the order';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_payment_capture(NULL, 'order_A', 'pay_A', 1000);
    RAISE EXCEPTION 'FAIL: a wrong webhook amount was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  PERFORM pg_temp.assert(pg_temp.balance(pt_id) = 0, 'nothing is credited before capture');

  res := grogu_payment_capture(dev_id, 'order_A', 'pay_A', NULL);
  PERFORM pg_temp.assert(NOT (res ->> 'alreadyPaid')::boolean AND res -> 'order' ->> 'status' = 'paid', 'the order is paid');
  PERFORM pg_temp.assert((res -> 'rewardPool' ->> 'balance')::int = 500, 'the pool is credited the stored amount');
  PERFORM pg_temp.assert((SELECT count(*) FROM notifications WHERE user_id = dev_id AND type = 'reward-pool-funded') = 1,
                         'the studio is told');

  -- The webhook arriving afterwards changes nothing.
  res := grogu_payment_capture(NULL, 'order_A', 'pay_A', 50000);
  PERFORM pg_temp.assert((res ->> 'alreadyPaid')::boolean, 'a second capture is a no-op');
  PERFORM pg_temp.assert(pg_temp.balance(pt_id) = 500, 'the pool is credited once');

  BEGIN
    UPDATE reward_pool_entries SET amount = 100000 WHERE playtest_id = pt_id;
    RAISE EXCEPTION 'FAIL: a pool entry was edited';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  BEGIN
    DELETE FROM reward_pool_entries WHERE playtest_id = pt_id;
    RAISE EXCEPTION 'FAIL: a pool entry was deleted';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  -- A failed order (Razorpay unreachable) cannot be captured by a stray webhook for another order id.
  ord := grogu_payment_order_prepare(dev_id, jsonb_build_object('playtestId', pt_id::text, 'amount', 200));
  PERFORM grogu_payment_order_fail((ord ->> 'id')::int, 'Razorpay unavailable');
  PERFORM pg_temp.assert((SELECT status FROM payment_orders WHERE id = (ord ->> 'id')::int) = 'failed', 'the order is marked failed');
  BEGIN
    PERFORM grogu_payment_capture(NULL, 'order_unknown', 'pay_U', 100);
    RAISE EXCEPTION 'FAIL: an unknown order was captured';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;

  /* ---- Cash rewards come out of the pool ---------------------------- */
  res := grogu_application_create(t1, pt_id, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev_id, (res ->> 'id')::int, 'accepted', NULL);
  res := grogu_application_create(t2, pt_id, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev_id, (res ->> 'id')::int, 'accepted', NULL);
  fb1 := (grogu_feedback_submit(t1, pt_id, jsonb_build_object('ratings', ratings, 'summary', 'One')) -> 'feedback' ->> 'id')::int;
  fb2 := (grogu_feedback_submit(t2, pt_id, jsonb_build_object('ratings', ratings, 'summary', 'Two')) -> 'feedback' ->> 'id')::int;

  PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"approved","cashAmount":300}');
  PERFORM pg_temp.assert(pg_temp.balance(pt_id) = 200, 'approval debits the pool');
  PERFORM pg_temp.assert((grogu_bootstrap(t1) -> 'wallet' ->> 'balance')::int = 300, 'the tester is credited');

  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb2, '{"decision":"approved","cashAmount":300}');
    RAISE EXCEPTION 'FAIL: approval spent more than the pool holds';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  PERFORM pg_temp.assert((SELECT review_status FROM feedback WHERE id = fb2) = 'submitted', 'the refused approval wrote nothing');
  PERFORM pg_temp.assert((grogu_bootstrap(t2) -> 'wallet' ->> 'balance')::int = 0, 'the refused approval paid nothing');

  -- Approval without cash needs no pool.
  PERFORM grogu_feedback_review(dev_id, fb2, '{"decision":"approved","cashAmount":0}');
  PERFORM pg_temp.assert(pg_temp.balance(pt_id) = 200, 'a cashless approval leaves the pool alone');

  res := grogu_reward_pool_view(dev_id, pt_id);
  PERFORM pg_temp.assert((res -> 'pool' ->> 'paidOut')::int = 300 AND (res -> 'pool' ->> 'funded')::int = 500, 'the summary adds up');
  PERFORM pg_temp.assert(jsonb_array_length(res -> 'entries') = 2 AND jsonb_array_length(res -> 'orders') = 1,
                         'the history lists entries and attached orders');
  BEGIN
    PERFORM grogu_reward_pool_view(other_dev, pt_id);
    RAISE EXCEPTION 'FAIL: another studio read the pool';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
END
$t$;

ROLLBACK;
