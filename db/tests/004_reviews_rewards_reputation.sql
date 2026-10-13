-- Review approval, rewards (reputation, cash ledger, game keys), reputation
-- earning rules, levels and the UPI wallet. Rolls back; leaves no data.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

CREATE FUNCTION pg_temp.rep(uid integer) RETURNS integer
  LANGUAGE sql AS $$ SELECT reputation FROM players WHERE user_id = uid $$;

CREATE FUNCTION pg_temp.consistent() RETURNS boolean
  LANGUAGE sql AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM players p
     WHERE p.reputation <> (SELECT coalesce(sum(e.amount), 0) FROM reputation_events e WHERE e.user_id = p.user_id))
$$;

CREATE FUNCTION pg_temp.notes(uid integer, t text) RETURNS integer
  LANGUAGE sql AS $$ SELECT count(*)::int FROM notifications WHERE user_id = uid AND type = t $$;

DO $t$
DECLARE
  dev_id    integer;
  other_dev integer;
  t1        integer;
  t2        integer;
  t3        integer;
  game      jsonb;
  game_id   integer;
  pt        jsonb;
  pt_id     integer;
  app       jsonb;
  fb1       integer;
  fb2       integer;
  fb3       integer;
  res       jsonb;
  doc       jsonb;
  key_id    integer;
  before    integer;
  ratings   jsonb := '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}';
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Rew Dev","email":"rewdev@test.invalid","password":"secret1","studioName":"Rew Studio"}') ->> 'id')::int;
  other_dev := (grogu_signup('{"role":"developer","name":"Rew Other","email":"rewother@test.invalid","password":"secret1","studioName":"Other"}') ->> 'id')::int;
  t1 := (grogu_signup('{"role":"tester","name":"Rew One","email":"rew1@test.invalid","password":"secret1"}') ->> 'id')::int;
  t2 := (grogu_signup('{"role":"tester","name":"Rew Two","email":"rew2@test.invalid","password":"secret1"}') ->> 'id')::int;
  t3 := (grogu_signup('{"role":"tester","name":"Rew Three","email":"rew3@test.invalid","password":"secret1"}') ->> 'id')::int;

  PERFORM pg_temp.assert(pg_temp.rep(t1) = 0, 'a new tester starts at 0 reputation');
  PERFORM pg_temp.assert((grogu_tester_profile_json((SELECT pl FROM players pl WHERE user_id = t1)) ->> 'level')::int = 1,
                         'a new tester is level 1');

  game    := grogu_game_save(dev_id, NULL, '{"title":"Reward Game","genres":["puzzle"],"platforms":["pc"]}');
  game_id := (game ->> 'id')::int;
  pt := grogu_playtest_save(dev_id, NULL, jsonb_build_object(
    'gameId', game_id, 'title', 'Reward playtest', 'maxTesters', 5, 'publish', true, 'cashReward', 300,
    'tasks', '[{"title":"Play","type":"objective","required":true}]'::jsonb));
  pt_id := (pt ->> 'id')::int;

  /* ---- Participation ------------------------------------------------ */
  FOREACH before IN ARRAY ARRAY[t1, t2, t3] LOOP
    app := grogu_application_create(before, pt_id, '{"agreedToTerms":true}');
    PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
  END LOOP;
  PERFORM pg_temp.assert(pg_temp.rep(t1) = 2, 'being accepted earns 2');
  -- Re-accepting the same application does not pay twice.
  PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
  PERFORM pg_temp.assert(pg_temp.rep(t3) = 2, 'acceptance is awarded once per playtest');

  fb1 := (grogu_feedback_submit(t1, pt_id, jsonb_build_object('ratings', ratings,
           'summary', repeat('Detailed notes. ', 10), 'highlights', '["a","b"]'::jsonb, 'bugs', '["c"]'::jsonb))
          -> 'feedback' ->> 'id')::int;
  fb2 := (grogu_feedback_submit(t2, pt_id, jsonb_build_object('ratings', ratings, 'summary', 'short'))
          -> 'feedback' ->> 'id')::int;
  fb3 := (grogu_feedback_submit(t3, pt_id, jsonb_build_object('ratings', ratings, 'summary', 'short'))
          -> 'feedback' ->> 'id')::int;
  PERFORM pg_temp.assert(pg_temp.rep(t1) = 2 + 10 + 5, 'completing earns 10 and a detailed review 5');
  PERFORM pg_temp.assert(pg_temp.rep(t2) = 2 + 10, 'a short review earns no detail bonus');

  doc := (SELECT f FROM jsonb_array_elements(grogu_bootstrap(t1) -> 'feedback') f WHERE (f ->> 'id')::int = fb1);
  PERFORM pg_temp.assert(doc ->> 'reviewStatus' = 'submitted', 'new feedback is submitted');
  PERFORM pg_temp.assert((doc -> 'rewards' ->> 'reputation')::int = 0, 'nothing is granted before approval');

  /* ---- Key inventory ------------------------------------------------ */
  res := grogu_game_keys_add(dev_id, game_id, '{"codes":["KEY-A"," KEY-A ","","KEY-B"]}');
  PERFORM pg_temp.assert((res ->> 'added')::int = 2, 'blank and duplicate keys are skipped');
  res := grogu_game_keys_add(dev_id, game_id, '{"codes":["KEY-B"]}');
  PERFORM pg_temp.assert((res ->> 'added')::int = 0 AND (res ->> 'skipped')::int = 1, 'an existing key is skipped');
  BEGIN
    PERFORM grogu_game_keys_add(other_dev, game_id, '{"codes":["X"]}');
    RAISE EXCEPTION 'FAIL: another studio added keys';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_keys_add(t1, game_id, '{"codes":["X"]}');
    RAISE EXCEPTION 'FAIL: a tester added keys';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(dev_id) -> 'gameKeys') = 2, 'the owner sees its keys');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(other_dev) -> 'gameKeys') = 0, 'another studio sees no keys');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(t1) -> 'gameKeys') = 0, 'a tester sees no keys');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(NULL) -> 'gameKeys') = 0, 'anonymous sees no keys');

  /* ---- Who may review ----------------------------------------------- */
  BEGIN
    PERFORM grogu_feedback_review(other_dev, fb1, '{"decision":"approved"}');
    RAISE EXCEPTION 'FAIL: another studio approved a review';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_review(t2, fb1, '{"decision":"approved"}');
    RAISE EXCEPTION 'FAIL: a tester approved a review';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"approved","reputationBonus":51}');
    RAISE EXCEPTION 'FAIL: a bonus over the cap was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"approved","cashAmount":-5}');
    RAISE EXCEPTION 'FAIL: a negative cash reward was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"approved","cashAmount":"lots"}');
    RAISE EXCEPTION 'FAIL: a non-numeric cash reward was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"maybe"}');
    RAISE EXCEPTION 'FAIL: an unknown decision was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  /* ---- Approval pays every reward once ------------------------------ */
  before := pg_temp.rep(t1);
  res := grogu_feedback_review(dev_id, fb1,
           '{"decision":"approved","reputationBonus":20,"cashAmount":300,"gameKey":true,"note":"Great"}');
  PERFORM pg_temp.assert(res ->> 'reviewStatus' = 'approved', 'the review is approved');
  PERFORM pg_temp.assert((res -> 'rewards' ->> 'reputation')::int = 35, 'approval 15 + bonus 20 is reported');
  PERFORM pg_temp.assert((res -> 'rewards' ->> 'cash')::int = 300, 'cash is reported');
  PERFORM pg_temp.assert((res -> 'rewards' ->> 'gameKey')::boolean, 'the key is reported');
  PERFORM pg_temp.assert(pg_temp.rep(t1) = before + 35, 'reputation moves by the approval and the bonus');
  PERFORM pg_temp.assert((grogu_bootstrap(t1) -> 'wallet' ->> 'balance')::int = 300, 'the balance is the ledger sum');
  PERFORM pg_temp.assert(pg_temp.notes(t1, 'feedback-approved') = 1 AND pg_temp.notes(t1, 'game-key-sent') = 1,
                         'the tester is told about the approval and the key');
  PERFORM pg_temp.assert((SELECT allocated_to FROM game_keys WHERE feedback_id = fb1) = t1, 'a key is allocated to the tester');

  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb1, '{"decision":"approved","cashAmount":300,"gameKey":true}');
    RAISE EXCEPTION 'FAIL: a review was approved twice';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  PERFORM pg_temp.assert((SELECT count(*) FROM ledger_entries WHERE user_id = t1) = 1, 'no second payment');

  -- The second approval takes the other key, never the same one.
  res := grogu_feedback_review(dev_id, fb2, '{"decision":"approved","gameKey":true}');
  PERFORM pg_temp.assert((SELECT count(DISTINCT id) FROM game_keys WHERE feedback_id IN (fb1, fb2)) = 2,
                         'two approvals get two different keys');
  PERFORM pg_temp.assert((grogu_bootstrap(t2) -> 'wallet' ->> 'balance')::int = 0, 'no cash means no ledger entry');

  -- The inventory is empty now: approval with a key fails and writes nothing.
  before := pg_temp.rep(t3);
  BEGIN
    PERFORM grogu_feedback_review(dev_id, fb3, '{"decision":"approved","gameKey":true,"cashAmount":100}');
    RAISE EXCEPTION 'FAIL: approval succeeded with no keys left';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  PERFORM pg_temp.assert((SELECT review_status FROM feedback WHERE id = fb3) = 'submitted', 'the failed approval left the review as it was');
  PERFORM pg_temp.assert(pg_temp.rep(t3) = before AND NOT EXISTS (SELECT 1 FROM ledger_entries WHERE user_id = t3),
                         'the failed approval paid nothing');

  -- A key can belong to one review only, even if someone bypasses the function.
  BEGIN
    UPDATE game_keys SET feedback_id = fb1 WHERE feedback_id = fb2;
    RAISE EXCEPTION 'FAIL: one review held two keys';
  EXCEPTION WHEN unique_violation THEN NULL; END;

  -- Ledger entries are append-only.
  BEGIN
    UPDATE ledger_entries SET amount = 1000000 WHERE user_id = t1;
    RAISE EXCEPTION 'FAIL: a ledger entry was edited';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  /* ---- Rejection ---------------------------------------------------- */
  res := grogu_feedback_review(dev_id, fb3, '{"decision":"rejected","note":"Too short","cashAmount":100}');
  PERFORM pg_temp.assert(res ->> 'reviewStatus' = 'rejected' AND res ->> 'reviewNote' = 'Too short', 'rejection is recorded');
  PERFORM pg_temp.assert((res -> 'rewards' ->> 'cash')::int = 0 AND pg_temp.rep(t3) = before, 'rejection pays nothing');
  PERFORM pg_temp.assert(pg_temp.notes(t3, 'feedback-rejected') = 1, 'the tester is told about the rejection');

  /* ---- Removing keys ------------------------------------------------ */
  SELECT id INTO key_id FROM game_keys WHERE feedback_id = fb1;
  BEGIN
    PERFORM grogu_game_key_delete(dev_id, game_id, key_id);
    RAISE EXCEPTION 'FAIL: an allocated key was deleted';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  res := grogu_game_keys_add(dev_id, game_id, '{"codes":["KEY-C"]}');
  SELECT k.id INTO key_id FROM game_keys k WHERE k.game_id = (game ->> 'id')::int AND k.code = 'KEY-C';
  BEGIN
    PERFORM grogu_game_key_delete(other_dev, game_id, key_id);
    RAISE EXCEPTION 'FAIL: another studio deleted a key';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  PERFORM grogu_game_key_delete(dev_id, game_id, key_id);
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM game_keys WHERE id = key_id), 'an unused key can be deleted');

  /* ---- Profile bonuses ---------------------------------------------- */
  before := pg_temp.rep(t2);
  PERFORM grogu_profile_save(t2, '{"bio":"Short bio."}');
  PERFORM pg_temp.assert(pg_temp.rep(t2) = before, 'a short bio earns nothing');
  PERFORM grogu_profile_save(t2, jsonb_build_object('bio', repeat('I test puzzle games carefully. ', 3)));
  PERFORM pg_temp.assert(pg_temp.rep(t2) = before + 5, 'a real bio earns 5');
  PERFORM grogu_profile_save(t2, jsonb_build_object('bio', repeat('Rewritten bio about my testing. ', 3)));
  PERFORM pg_temp.assert(pg_temp.rep(t2) = before + 5, 'the bio bonus is paid once');
  PERFORM grogu_profile_save(t2, '{"location":"Pune, IN","languages":["English"],"platforms":["pc"],"preferredGenres":["puzzle"]}');
  PERFORM pg_temp.assert(pg_temp.rep(t2) = before + 10, 'personal details earn 5');
  BEGIN
    PERFORM grogu_profile_save(t2, '{"avatarUrl":"javascript:alert(1)"}');
    RAISE EXCEPTION 'FAIL: a script avatar URL was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  PERFORM grogu_profile_save(t2, '{"avatarUrl":"/uploads/face.png"}');
  PERFORM pg_temp.assert(pg_temp.rep(t2) = before + 20, 'a profile picture earns 10');
  PERFORM pg_temp.assert(pg_temp.notes(t2, 'reputation-earned') = 3, 'each profile bonus is announced');

  /* ---- Levels ------------------------------------------------------- */
  -- t1 has 2 + 10 + 5 + 35 = 52: level 2 (25), next at 60.
  doc := grogu_tester_profile_json((SELECT pl FROM players pl WHERE user_id = t1));
  PERFORM pg_temp.assert((doc ->> 'reputation')::int = 52 AND (doc ->> 'level')::int = 2
                         AND (doc ->> 'levelFloor')::int = 25 AND (doc ->> 'nextLevelAt')::int = 60,
                         'level fields follow the threshold table');
  PERFORM pg_temp.assert(pg_temp.notes(t1, 'level-up') = 1, 'reaching level 2 was announced once');
  PERFORM grogu_reputation_award(t1, 'baseline', 'test', 10000);
  doc := grogu_tester_profile_json((SELECT pl FROM players pl WHERE user_id = t1));
  PERFORM pg_temp.assert((doc ->> 'level')::int = 8 AND doc -> 'nextLevelAt' = 'null'::jsonb, 'the top level has no next level');

  /* ---- UPI wallet --------------------------------------------------- */
  BEGIN
    PERFORM grogu_profile_save(t1, '{"upiId":"not a upi"}');
    RAISE EXCEPTION 'FAIL: a malformed UPI id was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  PERFORM grogu_profile_save(t1, '{"upiId":"rew.one@okbank"}');
  PERFORM pg_temp.assert(grogu_bootstrap(t1) -> 'wallet' ->> 'upiId' = 'rew.one@okbank', 'the owner sees their UPI id');
  PERFORM pg_temp.assert(grogu_bootstrap(t2) -> 'wallet' ->> 'upiId' = '', 'another tester does not');
  PERFORM pg_temp.assert(grogu_bootstrap(dev_id) -> 'wallet' = 'null'::jsonb, 'a studio has no wallet');
  PERFORM pg_temp.assert(grogu_bootstrap(NULL)::text NOT LIKE '%rew.one@okbank%', 'the UPI id never reaches anonymous viewers');

  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(t1) -> 'reputationEvents') > 0, 'the owner sees their history');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(NULL) -> 'reputationEvents') = 0, 'anonymous sees no history');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(NULL) -> 'reputationLevels') = 8, 'levels are public');

  PERFORM pg_temp.assert(pg_temp.consistent(), 'every cached reputation equals the sum of its events');
END
$t$;

ROLLBACK;
