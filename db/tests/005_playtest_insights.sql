-- Feedback insights: the rule-based summary, sentiment counts, the AI-summary
-- cache (staleness, validation, ownership) and the anonymised model input.
-- Rolls back; leaves no data.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

DO $t$
DECLARE
  dev_id    integer;
  other_dev integer;
  t1 integer; t2 integer; t3 integer; t4 integer;
  game      jsonb;
  pt_id     integer;
  empty_pt  integer;
  app       jsonb;
  v         jsonb;
  inp       jsonb;
  stored    jsonb;
  ratings   jsonb := '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}';
  last_id   integer;
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Ins Dev","email":"insdev@test.invalid","password":"secret1","studioName":"Ins Studio"}') ->> 'id')::int;
  other_dev := (grogu_signup('{"role":"developer","name":"Ins Other","email":"insother@test.invalid","password":"secret1","studioName":"Other"}') ->> 'id')::int;
  t1 := (grogu_signup('{"role":"tester","name":"Alice Tester","email":"alice.ins@test.invalid","password":"secret1"}') ->> 'id')::int;
  t2 := (grogu_signup('{"role":"tester","name":"Bob Tester","email":"bob.ins@test.invalid","password":"secret1"}') ->> 'id')::int;
  t3 := (grogu_signup('{"role":"tester","name":"Cara Tester","email":"cara.ins@test.invalid","password":"secret1"}') ->> 'id')::int;
  t4 := (grogu_signup('{"role":"tester","name":"Dan Tester","email":"dan.ins@test.invalid","password":"secret1"}') ->> 'id')::int;

  game := grogu_game_save(dev_id, NULL, '{"title":"Insight Game","genres":["puzzle"],"platforms":["pc"]}');
  pt_id := (grogu_playtest_save(dev_id, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Insight playtest', 'maxTesters', 6, 'publish', true,
    'tasks', '[{"title":"Play","type":"objective","required":true}]'::jsonb)) ->> 'id')::int;
  empty_pt := (grogu_playtest_save(dev_id, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Empty playtest', 'maxTesters', 2, 'publish', true)) ->> 'id')::int;

  /* ---- No feedback yet ---------------------------------------------- */
  v := grogu_insight_view(dev_id, empty_pt, NULL, true);
  PERFORM pg_temp.assert(v ->> 'source' = 'rules' AND (v ->> 'totalFeedback')::int = 0, 'no feedback gives the rules view');
  PERFORM pg_temp.assert((v ->> 'stale')::boolean = false, 'nothing to summarise is never stale');
  PERFORM pg_temp.assert(v ->> 'sentimentLabel' = 'none' AND v ->> 'summary' = 'No feedback has come in yet.', 'empty summary text');
  PERFORM pg_temp.assert(v ->> 'id' = empty_pt::text AND v ->> 'playtestId' = empty_pt::text, 'id is the playtest id');
  BEGIN
    PERFORM grogu_insight_store(dev_id, empty_pt, '{"summary":"x"}', 'm', 0, 0);
    RAISE EXCEPTION 'FAIL: a summary was stored with no feedback';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  /* ---- Feedback ----------------------------------------------------- */
  FOREACH last_id IN ARRAY ARRAY[t1, t2, t3] LOOP
    app := grogu_application_create(last_id, pt_id, '{"agreedToTerms":true}');
    PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
  END LOOP;

  -- Casing and whitespace differ, and Alice repeats herself: still two reviews.
  PERFORM grogu_feedback_submit(t1, pt_id, jsonb_build_object('ratings', ratings, 'sentiment', 'positive',
    'summary', 'Loved it.', 'highlights', '["Great audio","great audio ","Tight controls"]'::jsonb,
    'painPoints', '["Slow menus"]'::jsonb, 'bugs', '["Crash on pause"]'::jsonb, 'wouldRecommend', true));
  PERFORM grogu_feedback_submit(t2, pt_id, jsonb_build_object('ratings', ratings, 'sentiment', 'positive',
    'summary', 'Good.', 'highlights', '["GREAT AUDIO"]'::jsonb,
    'painPoints', '["Slow menus","Tutorial is unclear"]'::jsonb, 'bugs', '["crash on pause"]'::jsonb, 'wouldRecommend', true));
  PERFORM grogu_feedback_submit(t3, pt_id, jsonb_build_object('ratings', ratings, 'sentiment', 'negative',
    'summary', 'Meh.', 'highlights', '[]'::jsonb,
    'painPoints', '["Slow menus"]'::jsonb, 'bugs', '[]'::jsonb, 'wouldRecommend', false));

  v := grogu_insight_view(dev_id, pt_id, NULL, false);
  PERFORM pg_temp.assert(v ->> 'source' = 'rules' AND (v ->> 'totalFeedback')::int = 3 AND (v ->> 'feedbackCount')::int = 3,
                         'rules view covers all feedback');
  PERFORM pg_temp.assert((v -> 'sentiment' ->> 'positive')::int = 2 AND (v -> 'sentiment' ->> 'negative')::int = 1
                         AND (v -> 'sentiment' ->> 'neutral')::int = 0, 'sentiment counts come from the rows');
  PERFORM pg_temp.assert(v ->> 'sentimentLabel' = 'positive', 'two of three positive is positive');
  PERFORM pg_temp.assert((v ->> 'stale')::boolean AND NOT (v ->> 'aiEnabled')::boolean, 'stale until an AI summary exists; aiEnabled is passed through');
  PERFORM pg_temp.assert((v -> 'likes' -> 0 ->> 'mentions')::int = 2 AND lower(v -> 'likes' -> 0 ->> 'text') = 'great audio',
                         'repeated highlights merge case-insensitively, counted once per review');
  PERFORM pg_temp.assert((v -> 'dislikes' -> 0 ->> 'mentions')::int = 3 AND v -> 'dislikes' -> 0 ->> 'text' = 'Slow menus',
                         'pain points are ranked by reviews raising them');
  PERFORM pg_temp.assert((v -> 'bugs' -> 0 ->> 'mentions')::int = 2, 'bugs merge across casing');
  PERFORM pg_temp.assert(v ->> 'summary' LIKE '3 testers have reviewed this playtest: 2 positive, 0 neutral, 1 negative.%'
                         AND v ->> 'summary' LIKE '%67% would recommend%', 'summary text states the counts');
  PERFORM pg_temp.assert(jsonb_array_length(v -> 'highlights') = 3 AND v -> 'highlights' ->> 2 LIKE 'Most reported bug:%',
                         'rules takeaways name the top praise, complaint and bug');
  PERFORM pg_temp.assert(jsonb_array_length(v -> 'actions') = 0, 'rules give no suggested actions');
  PERFORM pg_temp.assert(v ->> 'notice' IS NULL, 'no notice by default');
  PERFORM pg_temp.assert((grogu_insight_view(dev_id, pt_id, '  ', true) -> 'notice') = 'null'::jsonb, 'a blank notice is dropped');
  PERFORM pg_temp.assert(grogu_insight_view(dev_id, pt_id, 'AI is off.', true) ->> 'notice' = 'AI is off.', 'the notice is passed through');

  /* ---- Ownership ---------------------------------------------------- */
  BEGIN
    PERFORM grogu_insight_view(other_dev, pt_id, NULL, true);
    RAISE EXCEPTION 'FAIL: another studio read the insights';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_insight_view(t1, pt_id, NULL, true);
    RAISE EXCEPTION 'FAIL: a tester read the insights';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_insight_prepare(other_dev, pt_id, true);
    RAISE EXCEPTION 'FAIL: another studio prepared an insight';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_insight_store(other_dev, pt_id, '{"summary":"hijack"}', 'm', 3, 1);
    RAISE EXCEPTION 'FAIL: another studio stored an insight';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_insight_store(t1, pt_id, '{"summary":"hijack"}', 'm', 3, 1);
    RAISE EXCEPTION 'FAIL: a tester stored an insight';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  /* ---- What the model is shown -------------------------------------- */
  v := grogu_insight_prepare(dev_id, pt_id, true);
  PERFORM pg_temp.assert((v ->> 'stale')::boolean AND (v ->> 'feedbackCount')::int = 3, 'prepare reports stale and the count');
  PERFORM pg_temp.assert(v ->> 'gameTitle' = 'Insight Game' AND v ->> 'title' = 'Insight playtest', 'prepare names the playtest and game');
  inp := v -> 'inputs';
  PERFORM pg_temp.assert(jsonb_array_length(inp) = 3, 'prepare includes every review when asked');
  PERFORM pg_temp.assert(inp::text NOT ILIKE '%alice%' AND inp::text NOT ILIKE '%bob%' AND inp::text NOT ILIKE '%cara%'
                         AND inp::text NOT ILIKE '%test.invalid%' AND inp::text NOT ILIKE '%testerId%',
                         'the model input carries no tester names, emails or ids');
  PERFORM pg_temp.assert(jsonb_array_length((grogu_insight_prepare(dev_id, pt_id, false)) -> 'inputs') = 0, 'inputs are skipped when not asked for');

  /* ---- Storing and staleness ---------------------------------------- */
  SELECT max(id) INTO last_id FROM feedback WHERE playtest_id = pt_id;
  stored := grogu_insight_store(dev_id, pt_id, jsonb_build_object(
    'summary', '  Testers enjoy the audio and controls but find menus slow.  ',
    'highlights', '["Audio is the standout","", 7, "Menus need work"]'::jsonb,
    'likes',    '[{"text":"Great audio","mentions":2},{"text":"  ","mentions":1},{"text":"Huge claim","mentions":999},{"text":"No count"}]'::jsonb,
    'dislikes', '[{"text":"Slow menus","mentions":-4}]'::jsonb,
    'bugs',     '"not a list"'::jsonb,
    'actions',  jsonb_build_array('a','b','c','d','e','f')), 'gemini-test', 3, last_id);
  PERFORM pg_temp.assert(stored ->> 'summary' = 'Testers enjoy the audio and controls but find menus slow.', 'summary is trimmed');
  PERFORM pg_temp.assert(stored -> 'highlights' = '["Audio is the standout","Menus need work"]'::jsonb, 'blank and non-string highlights are dropped');
  PERFORM pg_temp.assert(jsonb_array_length(stored -> 'likes') = 3, 'blank themes are dropped');
  PERFORM pg_temp.assert((stored -> 'likes' -> 1 ->> 'mentions')::int = 3, 'mentions are capped at the number of reviews');
  PERFORM pg_temp.assert((stored -> 'likes' -> 2 ->> 'mentions')::int = 1 AND (stored -> 'dislikes' -> 0 ->> 'mentions')::int = 1,
                         'missing or negative mentions become 1');
  PERFORM pg_temp.assert(stored -> 'bugs' = '[]'::jsonb, 'a non-list becomes an empty list');
  PERFORM pg_temp.assert(jsonb_array_length(stored -> 'actions') = 4, 'actions are capped at four');

  v := grogu_insight_view(dev_id, pt_id, NULL, true);
  PERFORM pg_temp.assert(v ->> 'source' = 'ai' AND v ->> 'model' = 'gemini-test' AND v ->> 'generatedAt' IS NOT NULL, 'the stored summary is served as ai');
  PERFORM pg_temp.assert(NOT (v ->> 'stale')::boolean AND (v ->> 'feedbackCount')::int = 3, 'fresh right after storing');
  PERFORM pg_temp.assert((v -> 'sentiment' ->> 'positive')::int = 2, 'sentiment counts stay live beside an ai summary');
  PERFORM pg_temp.assert(jsonb_array_length((grogu_insight_prepare(dev_id, pt_id, true)) -> 'inputs') = 0, 'a fresh summary needs no model input');

  -- A review arrives: the cached summary is kept but marked stale.
  app := grogu_application_create(t4, pt_id, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
  PERFORM grogu_feedback_submit(t4, pt_id, jsonb_build_object('ratings', ratings, 'sentiment', 'neutral', 'summary', 'ok'));
  v := grogu_insight_view(dev_id, pt_id, 'Try again later.', true);
  PERFORM pg_temp.assert(v ->> 'source' = 'ai' AND (v ->> 'stale')::boolean, 'new feedback makes the cached summary stale but keeps serving it');
  PERFORM pg_temp.assert((v ->> 'feedbackCount')::int = 3 AND (v ->> 'totalFeedback')::int = 4, 'covered versus total reviews');
  PERFORM pg_temp.assert(jsonb_array_length((grogu_insight_prepare(dev_id, pt_id, true)) -> 'inputs') = 4, 'a stale summary gets the model input again');

  -- Generating against the old count leaves it stale: nothing is lost if a
  -- review lands while the model is working.
  PERFORM grogu_insight_store(dev_id, pt_id, '{"summary":"Written from three reviews."}', 'gemini-test', 3, last_id);
  PERFORM pg_temp.assert((grogu_insight_view(dev_id, pt_id, NULL, true) ->> 'stale')::boolean, 'a summary written from old counts stays stale');
  SELECT max(id) INTO last_id FROM feedback WHERE playtest_id = pt_id;
  PERFORM grogu_insight_store(dev_id, pt_id, '{"summary":"Written from four reviews."}', 'gemini-test', 4, last_id);
  v := grogu_insight_view(dev_id, pt_id, NULL, true);
  PERFORM pg_temp.assert(NOT (v ->> 'stale')::boolean AND v ->> 'summary' = 'Written from four reviews.', 'storing replaces the previous summary');
  PERFORM pg_temp.assert((SELECT count(*) FROM playtest_insights WHERE playtest_id = pt_id) = 1, 'one cached row per playtest');

  /* ---- Validation --------------------------------------------------- */
  BEGIN
    PERFORM grogu_insight_store(dev_id, pt_id, '"just a string"'::jsonb, 'm', 4, last_id);
    RAISE EXCEPTION 'FAIL: a non-object summary was stored';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_insight_store(dev_id, pt_id, '{"summary":"   "}', 'm', 4, last_id);
    RAISE EXCEPTION 'FAIL: an empty summary was stored';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  stored := grogu_insight_store(dev_id, pt_id, jsonb_build_object('summary', repeat('x', 5000),
              'highlights', jsonb_build_array(repeat('y', 5000))), 'm', 4, last_id);
  PERFORM pg_temp.assert(length(stored ->> 'summary') = 700 AND length(stored -> 'highlights' ->> 0) = 220, 'long text is cut to its limit');

  /* ---- Deleting the playtest's feedback ----------------------------- */
  DELETE FROM feedback WHERE playtest_id = pt_id;
  v := grogu_insight_view(dev_id, pt_id, NULL, true);
  PERFORM pg_temp.assert(v ->> 'source' = 'rules' AND NOT (v ->> 'stale')::boolean, 'with no feedback left the cached summary is not shown');
END
$t$;

ROLLBACK;
