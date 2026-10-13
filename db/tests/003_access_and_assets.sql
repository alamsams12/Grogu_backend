-- Build access is limited to the owning studio and accepted testers, and asset
-- links (posters, review media) are validated. Rolls back; leaves no data.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

-- The playtest document as `viewer` receives it from the bootstrap payload.
CREATE FUNCTION pg_temp.seen(viewer integer, pid integer) RETURNS jsonb
  LANGUAGE sql AS $$
  SELECT p FROM jsonb_array_elements(grogu_bootstrap(viewer) -> 'playtests') p
   WHERE (p ->> 'id')::int = pid
$$;

DO $t$
DECLARE
  dev_id     integer;
  other_dev  integer;
  accepted   integer;
  pending    integer;
  stranger   integer;
  game       jsonb;
  pt         jsonb;
  pt_id      integer;
  app        jsonb;
  doc        jsonb;
  fb         jsonb;
BEGIN
  dev_id    := (grogu_signup('{"role":"developer","name":"Own Dev","email":"own@test.invalid","password":"secret1","studioName":"Own Studio"}') ->> 'id')::int;
  other_dev := (grogu_signup('{"role":"developer","name":"Other Dev","email":"otherdev@test.invalid","password":"secret1","studioName":"Other Studio"}') ->> 'id')::int;
  accepted  := (grogu_signup('{"role":"tester","name":"Accepted","email":"acc@test.invalid","password":"secret1"}') ->> 'id')::int;
  pending   := (grogu_signup('{"role":"tester","name":"Pending","email":"pend@test.invalid","password":"secret1"}') ->> 'id')::int;
  stranger  := (grogu_signup('{"role":"tester","name":"Stranger","email":"str@test.invalid","password":"secret1"}') ->> 'id')::int;

  -- Posters: uploads and https are accepted; script and data URLs are not.
  game := grogu_game_save(dev_id, NULL, '{"title":"Poster Game","coverImageUrl":"/uploads/abc123.png"}');
  PERFORM pg_temp.assert(game ->> 'coverImageUrl' = '/uploads/abc123.png', 'poster is stored');
  game := grogu_game_save(dev_id, (game ->> 'id')::int, '{"title":"Poster Game"}');
  PERFORM pg_temp.assert(game ->> 'coverImageUrl' = '/uploads/abc123.png', 'saving without the key keeps the poster');
  game := grogu_game_save(dev_id, (game ->> 'id')::int, '{"title":"Poster Game","coverImageUrl":null}');
  PERFORM pg_temp.assert(game ->> 'coverImageUrl' IS NULL, 'null clears the poster');
  game := grogu_game_save(dev_id, (game ->> 'id')::int, '{"title":"Poster Game","coverImageUrl":"https://cdn.example.com/p.png"}');
  PERFORM pg_temp.assert(game ->> 'coverImageUrl' = 'https://cdn.example.com/p.png', 'https poster is accepted');
  BEGIN
    PERFORM grogu_game_save(dev_id, (game ->> 'id')::int, '{"title":"Poster Game","coverImageUrl":"javascript:alert(1)"}');
    RAISE EXCEPTION 'FAIL: javascript: poster was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_game_save(dev_id, (game ->> 'id')::int, '{"title":"Poster Game","coverImageUrl":"/uploads/../etc/passwd"}');
    RAISE EXCEPTION 'FAIL: traversal poster was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- Build link validation.
  BEGIN
    PERFORM grogu_playtest_save(dev_id, NULL, jsonb_build_object(
      'gameId', game ->> 'id', 'title', 'Bad link', 'maxTesters', 2, 'publish', true,
      'buildUrl', 'javascript:alert(1)'));
    RAISE EXCEPTION 'FAIL: javascript: build link was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  pt := grogu_playtest_save(dev_id, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Access playtest', 'maxTesters', 2, 'publish', true,
    'buildUrl', 'https://builds.example.com/game', 'installInstructions', 'Unzip and run.', 'accessKey', 'KEY-1'));
  pt_id := (pt ->> 'id')::int;

  -- Visibility before anyone is accepted.
  doc := pg_temp.seen(NULL, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = '' AND doc ->> 'accessKey' = '' AND doc ->> 'installInstructions' = '',
                         'anonymous viewers see no access details');
  doc := pg_temp.seen(stranger, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = '' AND doc ->> 'accessKey' = '', 'a tester who has not applied sees nothing');
  doc := pg_temp.seen(other_dev, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = '' AND doc ->> 'accessKey' = '', 'another studio sees nothing');
  doc := pg_temp.seen(dev_id, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = 'https://builds.example.com/game' AND doc ->> 'accessKey' = 'KEY-1'
                         AND doc ->> 'installInstructions' = 'Unzip and run.', 'the owning studio sees its own details');

  -- A pending applicant still sees nothing; an accepted one does.
  PERFORM grogu_application_create(pending, pt_id, '{"agreedToTerms":true}');
  doc := pg_temp.seen(pending, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = '' AND doc ->> 'accessKey' = '', 'a pending applicant sees nothing');

  app := grogu_application_create(accepted, pt_id, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, 'accepted', NULL);
  doc := pg_temp.seen(accepted, pt_id);
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = 'https://builds.example.com/game' AND doc ->> 'accessKey' = 'KEY-1'
                         AND doc ->> 'installInstructions' = 'Unzip and run.', 'an accepted tester sees the details');

  -- Anonymous bootstrap never carries the details for any playtest.
  PERFORM pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(grogu_bootstrap(NULL) -> 'playtests') p
     WHERE p ->> 'buildUrl' <> '' OR p ->> 'accessKey' <> '' OR p ->> 'installInstructions' <> ''),
    'anonymous bootstrap carries no access details at all');

  -- Access updates: owner only, partial, validated.
  doc := grogu_playtest_access_save(dev_id, pt_id, '{"buildUrl":"https://builds.example.com/v2"}');
  PERFORM pg_temp.assert(doc ->> 'buildUrl' = 'https://builds.example.com/v2' AND doc ->> 'accessKey' = 'KEY-1',
                         'access save is partial and returns the owner view');
  BEGIN
    PERFORM grogu_playtest_access_save(other_dev, pt_id, '{"buildUrl":"https://evil.example.com"}');
    RAISE EXCEPTION 'FAIL: another studio changed the access details';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_access_save(accepted, pt_id, '{"buildUrl":"https://evil.example.com"}');
    RAISE EXCEPTION 'FAIL: a tester changed the access details';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_access_save(dev_id, pt_id, '{"buildUrl":"ftp://x"}');
    RAISE EXCEPTION 'FAIL: non-http build link was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- Review media: only uploaded files, only images/videos, at most six.
  PERFORM grogu_test_download(accepted, pt_id);
  BEGIN
    PERFORM grogu_feedback_submit(accepted, pt_id, jsonb_build_object(
      'ratings', '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}'::jsonb,
      'media', '[{"url":"https://tracker.example.com/pixel.png","kind":"image"}]'::jsonb));
    RAISE EXCEPTION 'FAIL: external media was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_submit(accepted, pt_id, jsonb_build_object(
      'ratings', '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}'::jsonb,
      'media', '[{"url":"/uploads/a.exe","kind":"program"}]'::jsonb));
    RAISE EXCEPTION 'FAIL: unknown media kind was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_feedback_submit(accepted, pt_id, jsonb_build_object(
      'ratings', '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}'::jsonb,
      'media', (SELECT jsonb_agg(jsonb_build_object('url', '/uploads/f' || n || '.png', 'kind', 'image'))
                  FROM generate_series(1, 7) n)));
    RAISE EXCEPTION 'FAIL: seven attachments were accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  fb := grogu_feedback_submit(accepted, pt_id, jsonb_build_object(
    'ratings', '{"fun":4,"difficulty":3,"clarity":4,"performance":4,"polish":4}'::jsonb,
    'media', '[{"url":"/uploads/shot1.png","kind":"image","name":"Boss fight"},{"url":"/uploads/run.mp4","kind":"video"}]'::jsonb));
  PERFORM pg_temp.assert(jsonb_array_length(fb -> 'feedback' -> 'media') = 2, 'valid media is stored');
  PERFORM pg_temp.assert(fb -> 'feedback' -> 'media' -> 0 ->> 'name' = 'Boss fight', 'media names are kept');
  PERFORM pg_temp.assert(
    jsonb_array_length((SELECT f -> 'media' FROM jsonb_array_elements(grogu_bootstrap(dev_id) -> 'feedback') f LIMIT 1)) = 2,
    'the studio receives the media with the feedback');
END
$t$;

ROLLBACK;
