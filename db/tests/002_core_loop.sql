-- The full product loop through the same functions the API calls:
-- game -> playtest -> apply -> accept -> download -> tasks -> feedback.
-- Rolls back; leaves no data.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

DO $t$
DECLARE
  dev_id    integer;
  tester_id integer;
  other_id  integer;
  game      jsonb;
  pt        jsonb;
  pt_id     integer;
  app       jsonb;
  app_id    integer;
  task_id   integer;
  fb        jsonb;
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Loop Dev","email":"loopdev@test.invalid","password":"secret1","studioName":"Loop Studio"}') ->> 'id')::int;
  tester_id := (grogu_signup('{"role":"tester","name":"Loop Tester","email":"looptester@test.invalid","password":"secret1"}') ->> 'id')::int;
  other_id  := (grogu_signup('{"role":"tester","name":"Other Tester","email":"other@test.invalid","password":"secret1"}') ->> 'id')::int;

  game := grogu_game_save(dev_id, NULL, '{"title":"Loop Game","genres":["puzzle"],"platforms":["pc"],"status":"beta"}');
  PERFORM pg_temp.assert(game ->> 'title' = 'Loop Game', 'game is created');

  pt := grogu_playtest_save(dev_id, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Loop playtest', 'summary', 's', 'maxTesters', 1, 'publish', true,
    'tasks', '[{"title":"Play","type":"objective","required":true},{"title":"Report","type":"survey","required":true}]'::jsonb));
  pt_id := (pt ->> 'id')::int;
  PERFORM pg_temp.assert(pt ->> 'status' = 'recruiting', 'published playtest is recruiting');
  PERFORM pg_temp.assert((SELECT count(*) FROM playtest_tasks WHERE playtest_id = pt_id) = 2, 'tasks are saved');

  -- applying requires accepting the terms
  BEGIN
    PERFORM grogu_application_create(tester_id, pt_id, '{"message":"hi"}');
    RAISE EXCEPTION 'FAIL: application without terms was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  app := grogu_application_create(tester_id, pt_id, '{"agreedToTerms":true,"message":"hi"}');
  app_id := (app ->> 'id')::int;
  PERFORM pg_temp.assert(app ->> 'status' = 'pending', 'new application is pending');

  -- applying twice is a conflict
  BEGIN
    PERFORM grogu_application_create(tester_id, pt_id, '{"agreedToTerms":true}');
    RAISE EXCEPTION 'FAIL: duplicate application was accepted';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  -- an unaccepted tester cannot open the workspace
  BEGIN
    PERFORM grogu_test_download(tester_id, pt_id);
    RAISE EXCEPTION 'FAIL: pending tester could download';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  -- a tester cannot decide on an application
  BEGIN
    PERFORM grogu_application_decide(other_id, app_id, 'accepted', NULL);
    RAISE EXCEPTION 'FAIL: a tester decided an application';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  app := grogu_application_decide(dev_id, app_id, 'accepted', NULL);
  PERFORM pg_temp.assert(app ->> 'status' = 'accepted', 'accepted by the owning studio');

  -- roster is capped at maxTesters
  app := grogu_application_create(other_id, pt_id, '{"agreedToTerms":true}');
  BEGIN
    PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
    RAISE EXCEPTION 'FAIL: roster cap not enforced';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  PERFORM grogu_test_download(tester_id, pt_id);
  FOR task_id IN SELECT id FROM playtest_tasks WHERE playtest_id = pt_id ORDER BY position LOOP
    PERFORM grogu_test_toggle_task(tester_id, pt_id, task_id);
  END LOOP;
  PERFORM pg_temp.assert(
    (SELECT build_downloaded FROM test_progress WHERE playtest_id = pt_id AND tester_user_id = tester_id),
    'download is recorded');

  fb := grogu_feedback_submit(tester_id, pt_id, '{"ratings":{"fun":4,"difficulty":3,"clarity":4,"performance":5,"polish":4},"sentiment":"positive","summary":"Good","hoursPlayed":2}');
  PERFORM pg_temp.assert((fb -> 'progress' ->> 'stage') = 'completed', 'feedback completes the test');

  -- feedback twice is a conflict
  BEGIN
    PERFORM grogu_feedback_submit(tester_id, pt_id, '{"ratings":{"fun":4,"difficulty":3,"clarity":4,"performance":5,"polish":4}}');
    RAISE EXCEPTION 'FAIL: second feedback was accepted';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  -- the studio was notified of the applicant and of the feedback
  PERFORM pg_temp.assert(
    (SELECT count(*) FROM notifications WHERE user_id = dev_id AND type IN ('application-received','feedback-received')) >= 2,
    'studio notifications created');
END
$t$;

ROLLBACK;
