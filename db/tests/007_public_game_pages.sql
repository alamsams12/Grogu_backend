-- Game slugs and links, the public game page, bug reports (incl. reputation
-- for confirmed bugs) and reviews (signed in and anonymous). Rolls back.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

CREATE FUNCTION pg_temp.notes(uid integer, t text) RETURNS integer
  LANGUAGE sql AS $$ SELECT count(*)::int FROM notifications WHERE user_id = uid AND type = t $$;

DO $t$
DECLARE
  dev_id    integer;
  other_dev integer;
  t1        integer;
  t2        integer;
  game      jsonb;
  game2     jsonb;
  game_id   integer;
  slug      text;
  pt_id     integer;
  page      jsonb;
  bug       jsonb;
  bug_id    integer;
  bug2_id   integer;
  anon_bug  jsonb;
  rev       jsonb;
  res       jsonb;
  rep0      integer;
  i         integer;
  ratings   jsonb := '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}';
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Page Dev","email":"pagedev@test.invalid","password":"secret123","studioName":"Page Studio"}') ->> 'id')::int;
  other_dev := (grogu_signup('{"role":"developer","name":"Page Other","email":"pageother@test.invalid","password":"secret123","studioName":"Other"}') ->> 'id')::int;
  t1 := (grogu_signup('{"role":"tester","name":"Page One","email":"page1@test.invalid","password":"secret123"}') ->> 'id')::int;
  t2 := (grogu_signup('{"role":"tester","name":"Page Two","email":"page2@test.invalid","password":"secret123"}') ->> 'id')::int;

  /* ---- Slugs and links ---------------------------------------------- */
  game := grogu_game_save(dev_id, NULL, '{"title":"Star Fox!! Tactics","genres":["strategy"],"platforms":["web"],
           "links":[{"kind":"web-play","url":"https://play.example.com/sft","label":"Play now"},
                    {"kind":"steam","url":""}]}');
  game_id := (game ->> 'id')::int;
  slug := game ->> 'slug';
  PERFORM pg_temp.assert(slug = 'star-fox-tactics', 'the slug comes from the title: ' || slug);
  PERFORM pg_temp.assert(jsonb_array_length(game -> 'links') = 1, 'empty links are dropped');
  PERFORM pg_temp.assert(game -> 'links' -> 0 ->> 'label' = 'Play now', 'a link keeps its label');

  game2 := grogu_game_save(other_dev, NULL, '{"title":"Star Fox Tactics"}');
  PERFORM pg_temp.assert(game2 ->> 'slug' = 'star-fox-tactics-2', 'a taken slug gets a suffix');

  res := grogu_game_save(dev_id, game_id, '{"title":"Renamed Game"}');
  PERFORM pg_temp.assert(res ->> 'slug' = slug, 'renaming keeps the slug');
  PERFORM pg_temp.assert(jsonb_array_length(res -> 'links') = 1, 'saving without links keeps them');

  BEGIN
    PERFORM grogu_game_save(dev_id, game_id, '{"title":"X","links":[{"kind":"website","url":"javascript:alert(1)"}]}');
    RAISE EXCEPTION 'FAIL: a javascript: link was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_save(dev_id, game_id, '{"title":"X","links":[{"kind":"warez","url":"https://x.test"}]}');
    RAISE EXCEPTION 'FAIL: an unknown link kind was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  /* ---- Public page -------------------------------------------------- */
  PERFORM pg_temp.assert(grogu_game_public('no-such-game', NULL) IS NULL, 'an unknown slug is not found');
  page := grogu_game_public(upper(slug), NULL);
  PERFORM pg_temp.assert(page -> 'game' ->> 'id' = game_id::text, 'the page is found by slug, any case');
  PERFORM pg_temp.assert(page -> 'studio' ->> 'studioName' = 'Page Studio', 'the page names the studio');
  PERFORM pg_temp.assert(page -> 'developer' ->> 'email' <> 'pagedev@test.invalid', 'the studio email is masked');
  PERFORM pg_temp.assert(NOT (page ->> 'viewerIsOwner')::boolean, 'anonymous is not the owner');
  PERFORM pg_temp.assert((grogu_game_public(slug, dev_id) ->> 'viewerIsOwner')::boolean, 'the studio is the owner');

  /* ---- Bug reports -------------------------------------------------- */
  BEGIN
    PERFORM grogu_bug_report_create(NULL, slug, '{"title":"Crash","description":"It crashes when I press start."}', NULL);
    RAISE EXCEPTION 'FAIL: an anonymous report without an IP hash was accepted';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_bug_report_create(t1, slug, '{"title":"Cr","description":"It crashes when I press start."}', 'h1');
    RAISE EXCEPTION 'FAIL: a two-letter title was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_bug_report_create(NULL, slug,
      '{"title":"Crash on start","description":"It crashes when I press start.","media":[{"url":"/uploads/a.png","kind":"image"}]}', 'h1');
    RAISE EXCEPTION 'FAIL: an anonymous report attached a file';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  bug := grogu_bug_report_create(t1, slug, '{"title":"Crash on start","description":"It crashes when I press start.",
           "severity":"high","platform":"Chrome 130 on Windows","buildVersion":"1.2.0","source":"badge",
           "contactEmail":"ignored@test.invalid"}', 'h1');
  bug_id := (bug ->> 'id')::int;
  PERFORM pg_temp.assert(bug ->> 'status' = 'new' AND bug ->> 'source' = 'badge', 'a report starts as new');
  PERFORM pg_temp.assert(NOT bug ? 'contactEmail', 'the reporter''s copy has no contact field');
  PERFORM pg_temp.assert(pg_temp.notes(dev_id, 'bug-reported') = 1, 'the studio is told about the report');

  anon_bug := grogu_bug_report_create(NULL, slug, '{"title":"Typo in menu","description":"The options menu says Optoins.",
                "reporterName":"Sam","contactEmail":"sam@test.invalid"}', 'anon-hash');
  PERFORM pg_temp.assert((anon_bug ->> 'anonymous')::boolean AND anon_bug ->> 'reporterName' = 'Sam', 'anonymous reports work');
  bug2_id := (anon_bug ->> 'id')::int;
  BEGIN
    PERFORM grogu_bug_report_create(NULL, slug, '{"title":"Bad mail","description":"Testing a bad email here.","contactEmail":"nope"}', 'anon-hash');
    RAISE EXCEPTION 'FAIL: an invalid email was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- Five anonymous reports an hour per IP hash.
  FOR i IN 2..5 LOOP
    PERFORM grogu_bug_report_create(NULL, slug, jsonb_build_object('title', 'Spam report ' || i,
              'description', 'Repeated report number ' || i), 'anon-hash');
  END LOOP;
  BEGIN
    PERFORM grogu_bug_report_create(NULL, slug, '{"title":"One more","description":"This one is over the limit."}', 'anon-hash');
    RAISE EXCEPTION 'FAIL: the anonymous hourly limit did not apply';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  -- Only the owner reads the inbox, with contact details.
  res := grogu_game_bugs(dev_id, game_id);
  PERFORM pg_temp.assert(jsonb_array_length(res) = 6, 'the owner sees every report');
  PERFORM pg_temp.assert((SELECT b ->> 'contactEmail' FROM jsonb_array_elements(res) b WHERE (b ->> 'id')::int = bug2_id)
                         = 'sam@test.invalid', 'the owner sees an anonymous reporter''s email');
  PERFORM pg_temp.assert((SELECT b ->> 'contactEmail' FROM jsonb_array_elements(res) b WHERE (b ->> 'id')::int = bug_id)
                         = 'page1@test.invalid', 'a signed-in reporter is reached through their account');
  PERFORM pg_temp.assert(NOT res::text LIKE '%anon-hash%', 'the IP hash is never returned');
  BEGIN
    PERFORM grogu_game_bugs(other_dev, game_id);
    RAISE EXCEPTION 'FAIL: another studio read the inbox';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_bugs(t1, game_id);
    RAISE EXCEPTION 'FAIL: a tester read the inbox';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  -- Reports are not public; a reporter sees only their own.
  PERFORM pg_temp.assert(jsonb_array_length(grogu_game_public(slug, NULL) -> 'viewerBugReports') = 0, 'anonymous sees no reports');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_game_public(slug, t1) -> 'viewerBugReports') = 1, 'a reporter sees their own report');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_game_public(slug, t2) -> 'viewerBugReports') = 0, 'others don''t see it');

  -- Confirming awards reputation once; later statuses don't pay again.
  rep0 := (SELECT reputation FROM players WHERE user_id = t1);
  BEGIN
    PERFORM grogu_bug_report_update(other_dev, bug_id, '{"status":"confirmed"}');
    RAISE EXCEPTION 'FAIL: another studio changed a report';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  res := grogu_bug_report_update(dev_id, bug_id, '{"status":"confirmed","developerNote":"Thanks, reproduced."}');
  PERFORM pg_temp.assert(res ->> 'status' = 'confirmed' AND (res ->> 'reputationAwarded')::int = 10, 'confirming awards 10');
  PERFORM pg_temp.assert((SELECT reputation FROM players WHERE user_id = t1) = rep0 + 10, 'the reporter''s reputation moves');
  PERFORM grogu_bug_report_update(dev_id, bug_id, '{"status":"in-progress"}');
  PERFORM grogu_bug_report_update(dev_id, bug_id, '{"status":"fixed"}');
  PERFORM pg_temp.assert((SELECT reputation FROM players WHERE user_id = t1) = rep0 + 10, 'a report pays once');
  PERFORM pg_temp.assert(pg_temp.notes(t1, 'bug-status') = 3, 'the reporter hears about each status change');
  PERFORM pg_temp.assert((grogu_game_public(slug, NULL) ->> 'bugsFixed')::int = 1, 'fixed bugs are counted publicly');

  -- Duplicates point at another report of the same game.
  BEGIN
    PERFORM grogu_bug_report_update(dev_id, bug2_id, jsonb_build_object('status', 'duplicate', 'duplicateOf', bug2_id::text));
    RAISE EXCEPTION 'FAIL: a report was marked a duplicate of itself';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  res := grogu_bug_report_update(dev_id, bug2_id, jsonb_build_object('status', 'duplicate', 'duplicateOf', bug_id::text));
  PERFORM pg_temp.assert(res ->> 'duplicateOf' = bug_id::text, 'a duplicate links the original');
  BEGIN
    PERFORM grogu_bug_report_update(dev_id, bug2_id, '{"status":"maybe"}');
    RAISE EXCEPTION 'FAIL: an unknown status was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- The studio's games list gets counts.
  res := (SELECT a FROM jsonb_array_elements(grogu_bootstrap(dev_id) -> 'gameActivity') a WHERE a ->> 'gameId' = game_id::text);
  PERFORM pg_temp.assert((res ->> 'totalBugs')::int = 6 AND (res ->> 'newBugs')::int = 4, 'gameActivity counts reports');
  PERFORM pg_temp.assert(jsonb_array_length(grogu_bootstrap(t1) -> 'gameActivity') = 0, 'testers get no gameActivity');

  /* ---- Reviews ------------------------------------------------------ */
  BEGIN
    PERFORM grogu_game_review_save(dev_id, slug, '{"rating":5,"body":"My own game is the best."}', 'h');
    RAISE EXCEPTION 'FAIL: a studio reviewed its own game';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_review_save(t1, slug, '{"rating":0,"body":"No stars at all here."}', 'h');
    RAISE EXCEPTION 'FAIL: a zero rating was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_review_save(t1, slug, '{"rating":4,"body":"Short"}', 'h');
    RAISE EXCEPTION 'FAIL: a too-short review was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  rev := grogu_game_review_save(t1, slug, '{"rating":4,"body":"Great puzzles, rough menus."}', 'h');
  PERFORM pg_temp.assert(NOT (rev ->> 'anonymous')::boolean AND rev ->> 'authorName' = 'Page One', 'a signed-in review names its author');
  PERFORM pg_temp.assert(NOT (rev ->> 'verified')::boolean, 'a non-tester is not verified');
  rev := grogu_game_review_save(t1, slug, '{"rating":2,"body":"Changed my mind after the update."}', 'h');
  PERFORM pg_temp.assert((SELECT count(*) FROM game_reviews r WHERE r.game_id = (game ->> 'id')::int AND r.user_id = t1) = 1, 'editing keeps one review');
  PERFORM pg_temp.assert((rev ->> 'rating')::int = 2, 'the edit is saved');
  PERFORM pg_temp.assert(pg_temp.notes(dev_id, 'review-received') = 1, 'the studio is told once, on the first review');

  rev := grogu_game_review_save(NULL, slug, '{"rating":5,"body":"Loved it, played twice.","authorName":"Kai"}', 'anon-r');
  PERFORM pg_temp.assert((rev ->> 'anonymous')::boolean AND rev ->> 'authorName' = 'Kai', 'anonymous reviews work');
  BEGIN
    PERFORM grogu_game_review_save(NULL, slug, '{"rating":1,"body":"Second one from the same place."}', 'anon-r');
    RAISE EXCEPTION 'FAIL: two anonymous reviews from one IP hash';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_review_save(NULL, slug, '{"rating":1,"body":"No IP hash on this one."}', NULL);
    RAISE EXCEPTION 'FAIL: an anonymous review without an IP hash';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  page := grogu_game_public(slug, t1);
  PERFORM pg_temp.assert((page -> 'game' -> 'rating' ->> 'count')::int = 2, 'the rating counts both reviews');
  PERFORM pg_temp.assert((page -> 'game' -> 'rating' ->> 'average')::numeric = 3.5, 'the average is (2 + 5) / 2');
  PERFORM pg_temp.assert((page -> 'ratingBreakdown' ->> '5')::int = 1, 'the breakdown counts each star');
  PERFORM pg_temp.assert((page -> 'viewerReview' ->> 'rating')::int = 2, 'the viewer sees their own review');
  PERFORM pg_temp.assert(NOT page::text LIKE '%anon-r%', 'the IP hash is never returned');

  -- Verified: the reviewer submitted feedback in one of the game's playtests.
  pt_id := (grogu_playtest_save(dev_id, NULL, jsonb_build_object('gameId', game_id, 'title', 'Page test',
              'maxTesters', 5, 'publish', true, 'tasks', '[{"title":"Play","type":"objective","required":true}]'::jsonb)) ->> 'id')::int;
  res := grogu_application_create(t2, pt_id, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev_id, (res ->> 'id')::int, 'accepted', NULL);
  PERFORM grogu_feedback_submit(t2, pt_id, jsonb_build_object('ratings', ratings, 'summary', 'Played it.'));
  rev := grogu_game_review_save(t2, slug, '{"rating":5,"body":"Tested it, it is good."}', 'h2');
  PERFORM pg_temp.assert((rev ->> 'verified')::boolean, 'a playtester''s review is verified');
  page := grogu_game_public(slug, NULL);
  PERFORM pg_temp.assert((page -> 'verifiedRating' ->> 'count')::int = 1, 'verified reviews are counted separately');
  PERFORM pg_temp.assert(jsonb_array_length(page -> 'openPlaytests') = 1, 'open playtests are listed');
  PERFORM pg_temp.assert(page -> 'openPlaytests' -> 0 ->> 'buildUrl' = '', 'the public page carries no build link');

  -- Replies: owner only; an empty reply removes it.
  BEGIN
    PERFORM grogu_game_review_reply(other_dev, (rev ->> 'id')::int, '{"reply":"Hi"}');
    RAISE EXCEPTION 'FAIL: another studio replied';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  res := grogu_game_review_reply(dev_id, (rev ->> 'id')::int, '{"reply":"Thanks for testing!"}');
  PERFORM pg_temp.assert(res ->> 'developerReply' = 'Thanks for testing!', 'the reply is saved');
  PERFORM pg_temp.assert(pg_temp.notes(t2, 'review-reply') = 1, 'the reviewer is told about the reply');
  res := grogu_game_review_reply(dev_id, (rev ->> 'id')::int, '{"reply":""}');
  PERFORM pg_temp.assert(res ->> 'developerReply' IS NULL, 'an empty reply removes it');
END
$t$;

ROLLBACK;
