-- Matching: eligibility filters, scoring and weights, reasons, the AI-ranking
-- cache, access control, and invitations. Uses its own accounts and playtests,
-- so the seeded data cannot make a check pass by accident. Rolls back.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

-- Is this tester suggested for this playtest (studio side)?
CREATE FUNCTION pg_temp.suggested(pt integer, tester integer) RETURNS boolean
  LANGUAGE sql AS $$ SELECT EXISTS (SELECT 1 FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = tester) $$;

CREATE FUNCTION pg_temp.tester(name text, profile jsonb, rep integer) RETURNS integer
  LANGUAGE plpgsql AS $$
DECLARE uid integer;
BEGIN
  uid := (grogu_signup(jsonb_build_object('role', 'tester', 'name', name,
            'email', lower(replace(name, ' ', '.')) || '@match.test.invalid', 'password', 'secret1') || profile) ->> 'id')::int;
  PERFORM set_config('grogu.quiet', 'on', true);
  PERFORM grogu_reputation_award(uid, 'baseline', 'match-test', rep);
  PERFORM set_config('grogu.quiet', 'off', true);
  RETURN uid;
END $$;

DO $t$
DECLARE
  dev      integer;
  other    integer;
  game     jsonb;
  pt       integer;      -- the main playtest: strategy/rpg on PC, hardcore+, 50+ rep, 4 h
  pt_full  integer;
  pt_draft integer;
  pt_any   integer;      -- no requirements at all
  ideal    integer;      -- fits everything
  okay     integer;      -- fits, weaker genre match
  wrongpf  integer;      -- console only
  wronglng integer;      -- speaks only German
  novice   integer;      -- casual experience
  lowrep   integer;      -- 10 reputation
  applied  integer;
  withdrew integer;
  doc      jsonb;
  fp       text;
  app      jsonb;
  n        integer;
  first_id text;
  i        integer;
BEGIN
  dev   := (grogu_signup('{"role":"developer","name":"Match Dev","email":"matchdev@test.invalid","password":"secret1","studioName":"Match Studio"}') ->> 'id')::int;
  other := (grogu_signup('{"role":"developer","name":"Match Other","email":"matchother@test.invalid","password":"secret1","studioName":"Other Studio"}') ->> 'id')::int;

  game := grogu_game_save(dev, NULL, '{"title":"Match Game","genres":["strategy","rpg"],"platforms":["pc"]}');

  pt := (grogu_playtest_save(dev, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Match playtest', 'maxTesters', 5, 'publish', true, 'cashReward', 300,
    -- Esperanto: only this test's testers speak it, so seeded testers stay out.
    'requirements', '{"minExperienceLevel":"hardcore","platforms":["pc"],"preferredGenres":["strategy","rpg"],"languages":["Esperanto"],"minReputation":50,"estimatedHours":4,"ndaRequired":false}'::jsonb))
    ->> 'id')::int;
  pt_full := (grogu_playtest_save(dev, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Full playtest', 'maxTesters', 1, 'publish', true,
    'requirements', '{"minExperienceLevel":"casual","platforms":[],"preferredGenres":[],"languages":[],"minReputation":0,"estimatedHours":1,"ndaRequired":false}'::jsonb))
    ->> 'id')::int;
  pt_draft := (grogu_playtest_save(dev, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Draft playtest', 'maxTesters', 5, 'publish', false)) ->> 'id')::int;
  pt_any := (grogu_playtest_save(dev, NULL, jsonb_build_object(
    'gameId', game ->> 'id', 'title', 'Open-to-all playtest', 'maxTesters', 5, 'publish', true,
    'requirements', '{"minExperienceLevel":"casual","platforms":[],"preferredGenres":[],"languages":[],"minReputation":0,"estimatedHours":2,"ndaRequired":false}'::jsonb))
    ->> 'id')::int;

  ideal    := pg_temp.tester('Ideal Match',   '{"experienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);
  okay     := pg_temp.tester('Okay Match',    '{"experienceLevel":"hardcore","platforms":["pc","mac"],"preferredGenres":["strategy","puzzle"],"weeklyAvailabilityHours":2}', 60);
  wrongpf  := pg_temp.tester('Console Only',  '{"experienceLevel":"professional","platforms":["console"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);
  wronglng := pg_temp.tester('German Only',   '{"experienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);
  UPDATE players SET languages = ARRAY['German'] WHERE user_id = wronglng;
  novice   := pg_temp.tester('Casual Player', '{"experienceLevel":"casual","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);
  lowrep   := pg_temp.tester('Low Rep',       '{"experienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 10);
  applied  := pg_temp.tester('Already Applied','{"experienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);
  withdrew := pg_temp.tester('Withdrew',      '{"experienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":10}', 200);

  UPDATE players SET languages = ARRAY['English', 'Esperanto']
   WHERE user_id IN (ideal, okay, wrongpf, novice, lowrep, applied, withdrew);

  PERFORM grogu_application_create(applied, pt, '{"agreedToTerms":true}');
  app := grogu_application_create(withdrew, pt, '{"agreedToTerms":true}');
  PERFORM grogu_application_withdraw(withdrew, (app ->> 'id')::int);
  -- Fill the one-slot playtest.
  app := grogu_application_create(okay, pt_full, '{"agreedToTerms":true}');
  PERFORM grogu_application_decide(dev, (app ->> 'id')::int, 'accepted', NULL);

  /* ---- Eligibility -------------------------------------------------- */
  PERFORM pg_temp.assert(pg_temp.suggested(pt, ideal), 'a tester who fits everything is suggested');
  PERFORM pg_temp.assert(pg_temp.suggested(pt, okay), 'a tester who meets every requirement is suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, wrongpf), 'no required platform: not suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, wronglng), 'no required language: not suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, novice), 'below the minimum experience: not suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, lowrep), 'below the minimum reputation: not suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, applied), 'already applied: not suggested');
  PERFORM pg_temp.assert(NOT pg_temp.suggested(pt, withdrew), 'withdrew: not suggested again');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('studio', pt_full, NULL)), 'a full playtest has no suggestions');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('studio', pt_draft, NULL)), 'a draft has no suggestions');
  PERFORM pg_temp.assert(pg_temp.suggested(pt_any, wrongpf) AND pg_temp.suggested(pt_any, wronglng) AND pg_temp.suggested(pt_any, novice),
                         'empty requirements filter nobody out');
  UPDATE playtests SET closes_at = now() - interval '1 day' WHERE id = pt_any;
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('studio', pt_any, NULL)), 'a playtest past its closing date has no suggestions');
  UPDATE playtests SET closes_at = now() + interval '10 days' WHERE id = pt_any;

  -- The tester side applies the same filters.
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('tester', NULL, wrongpf) WHERE pt_id = pt), 'tester side: platform filter');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('tester', NULL, applied) WHERE pt_id = pt), 'tester side: applied playtests are not recommended');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('tester', NULL, ideal) WHERE pt_id IN (pt_full, pt_draft)),
                         'tester side: full playtests and drafts are not recommended');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM grogu_match_candidates('tester', NULL, ideal) WHERE pt_id = pt), 'tester side: a fitting playtest is recommended');

  /* ---- Scores and reasons ------------------------------------------- */
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM grogu_match_candidates('studio', pt, NULL) WHERE score < 0 OR score > 100),
                         'scores stay within 0 to 100');
  PERFORM pg_temp.assert(
    (SELECT score FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = ideal)
      > (SELECT score FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = okay),
    'the better fit scores higher');
  PERFORM pg_temp.assert(
    (SELECT reasons[1] FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = ideal) = 'Plays RPG and Strategy',
    'the strongest reason comes first and names the shared genres');
  PERFORM pg_temp.assert(
    (SELECT cardinality(reasons) BETWEEN 1 AND 3 FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = okay),
    'one to three reasons');
  PERFORM pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM grogu_match_candidates('studio', pt, NULL) c, unnest(c.reasons) r WHERE r LIKE 'Finished 0 of%'),
    'a weakness is never given as a reason');
  PERFORM pg_temp.assert(
    (SELECT factors ->> 'availability' FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = okay)::numeric = 0.5,
    'availability is weekly hours against the estimate (2 of 4)');

  -- Weights are data: making availability the only factor flips the order.
  UPDATE matching_weights SET weight = 0 WHERE context = 'studio';
  UPDATE matching_weights SET weight = 10 WHERE context = 'studio' AND factor = 'availability';
  PERFORM pg_temp.assert((SELECT score FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = ideal) = 100
                         AND (SELECT score FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = okay) = 50,
                         'with a single factor the score is that factor');
  UPDATE matching_weights SET weight = 0 WHERE context = 'studio';
  PERFORM pg_temp.assert((SELECT score FROM grogu_match_candidates('studio', pt, NULL) WHERE tester_id = ideal) = 0,
                         'with every weight at zero the score is zero, not an error');
  UPDATE matching_weights m SET weight = d.w
    FROM (VALUES ('genre',30),('reputation',20),('reliability',20),('quality',10),('availability',10),('experience',10)) d(f, w)
   WHERE m.context = 'studio' AND m.factor = d.f;

  /* ---- Studio view and access --------------------------------------- */
  doc := grogu_tester_suggestions_view(dev, pt, NULL, true);
  PERFORM pg_temp.assert(doc ->> 'source' = 'rules' AND (doc ->> 'stale')::boolean AND (doc ->> 'open')::boolean, 'rules view, stale until AI ranks it');
  PERFORM pg_temp.assert(doc -> 'suggestions' -> 0 ->> 'testerId' = ideal::text, 'best fit first');
  PERFORM pg_temp.assert((doc ->> 'eligibleCount')::int >= 2, 'eligible count is reported');
  PERFORM pg_temp.assert(jsonb_array_length(doc -> 'suggestions') <= 10, 'at most ten suggestions');
  PERFORM pg_temp.assert(doc -> 'suggestions' -> 0 -> 'aiReason' = 'null'::jsonb, 'no AI reason before AI ranks it');
  doc := grogu_tester_suggestions_view(dev, pt_draft, NULL, true);
  PERFORM pg_temp.assert(NOT (doc ->> 'open')::boolean AND jsonb_array_length(doc -> 'suggestions') = 0
                         AND NOT (doc ->> 'stale')::boolean, 'a draft is not open and has nothing to rank');
  BEGIN
    PERFORM grogu_tester_suggestions_view(other, pt, NULL, true);
    RAISE EXCEPTION 'FAIL: another studio saw the suggestions';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_tester_suggestions_view(ideal, pt, NULL, true);
    RAISE EXCEPTION 'FAIL: a tester saw a studio''s suggestions';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_recommendations_view(dev, NULL, true);
    RAISE EXCEPTION 'FAIL: a studio got tester recommendations';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;

  /* ---- Model input carries no identities ---------------------------- */
  doc := grogu_tester_suggestions_prepare(dev, pt);
  PERFORM pg_temp.assert((doc ->> 'stale')::boolean AND jsonb_array_length(doc -> 'candidates') >= 2, 'prepare lists the shortlist');
  PERFORM pg_temp.assert(doc::text NOT ILIKE '%Ideal Match%' AND doc::text NOT ILIKE '%test.invalid%'
                         AND doc::text NOT ILIKE '%"bio"%' AND doc::text NOT ILIKE '%"name"%',
                         'no names, emails or bios in the model input');
  fp := doc ->> 'fingerprint';

  /* ---- AI ranking cache ---------------------------------------------- */
  -- The AI puts `okay` first, mentions an id that is not in the list, and
  -- leaves `ideal` out. Unknown ids are ignored; omitted ones follow in rule order.
  PERFORM grogu_match_store(dev, 'studio', pt, fp, jsonb_build_array(
    jsonb_build_object('id', okay::text, 'reason', '  Strong strategy player.  '),
    jsonb_build_object('id', '999999', 'reason', 'Not in the list'),
    jsonb_build_object('id', okay::text, 'reason', 'duplicate')), 'gemini-test');
  doc := grogu_tester_suggestions_view(dev, pt, NULL, true);
  PERFORM pg_temp.assert(doc ->> 'source' = 'ai' AND NOT (doc ->> 'stale')::boolean AND doc ->> 'model' = 'gemini-test', 'a matching AI ranking is used');
  PERFORM pg_temp.assert(doc -> 'suggestions' -> 0 ->> 'testerId' = okay::text, 'AI order is applied');
  PERFORM pg_temp.assert(doc -> 'suggestions' -> 0 ->> 'aiReason' = 'Strong strategy player.', 'AI reason is trimmed, first entry kept');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(doc -> 'suggestions') s WHERE s ->> 'testerId' = '999999'),
                         'the AI cannot add a tester');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM jsonb_array_elements(doc -> 'suggestions') s WHERE s ->> 'testerId' = ideal::text),
                         'testers the AI left out are still listed');
  SELECT count(*) INTO n FROM jsonb_array_elements(doc -> 'suggestions') s WHERE s ->> 'testerId' = okay::text;
  PERFORM pg_temp.assert(n = 1, 'a tester appears once');

  -- The list changes (someone applies): the AI ranking no longer applies.
  PERFORM grogu_application_create(okay, pt, '{"agreedToTerms":true}');
  doc := grogu_tester_suggestions_view(dev, pt, 'busy', true);
  PERFORM pg_temp.assert(doc ->> 'source' = 'rules' AND (doc ->> 'stale')::boolean AND doc ->> 'notice' = 'busy',
                         'a changed list falls back to rule order and is stale');

  BEGIN
    PERFORM grogu_match_store(other, 'studio', pt, fp, '[{"id":"1"}]', 'm');
    RAISE EXCEPTION 'FAIL: another studio stored a ranking';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_match_store(ideal, 'tester', okay, 'x', '[{"id":"1"}]', 'm');
    RAISE EXCEPTION 'FAIL: a tester stored someone else''s ranking';
  EXCEPTION WHEN SQLSTATE 'GR004' THEN NULL; END;
  BEGIN
    PERFORM grogu_match_store(dev, 'studio', pt, fp, '{"id":"1"}', 'm');
    RAISE EXCEPTION 'FAIL: a non-list ranking was stored';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_match_store(dev, 'studio', pt, fp, '[{"id":"not-a-number"}]', 'm');
    RAISE EXCEPTION 'FAIL: a ranking with no usable ids was stored';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;
  BEGIN
    PERFORM grogu_match_store(dev, 'other', pt, fp, '[{"id":"1"}]', 'm');
    RAISE EXCEPTION 'FAIL: an unknown kind was stored';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  /* ---- Invitations ---------------------------------------------------- */
  doc := grogu_playtest_invite(dev, pt, ideal);
  PERFORM pg_temp.assert((doc ->> 'invited')::boolean, 'a studio can invite a suggested tester');
  PERFORM grogu_playtest_invite(dev, pt, ideal);
  PERFORM pg_temp.assert((SELECT count(*) FROM notifications WHERE user_id = ideal AND type = 'playtest-invite') = 1,
                         'inviting twice notifies once');
  PERFORM pg_temp.assert((SELECT href FROM notifications WHERE user_id = ideal AND type = 'playtest-invite') = '/playtests/' || pt,
                         'the invite links to the playtest');
  PERFORM pg_temp.assert(
    (SELECT s ->> 'invited' FROM jsonb_array_elements(grogu_tester_suggestions_view(dev, pt, NULL, true) -> 'suggestions') s
      WHERE s ->> 'testerId' = ideal::text)::boolean, 'the studio sees who it invited');

  -- On the tester side the invite raises the playtest and says why.
  doc := grogu_playtest_recommendations_view(ideal, NULL, true);
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM jsonb_array_elements(doc -> 'recommendations') r
                                  WHERE r ->> 'playtestId' = pt::text AND (r ->> 'invited')::boolean
                                    AND r -> 'reasons' ? 'Invited by Match Studio'),
                         'an invited playtest says who invited the tester');
  PERFORM pg_temp.assert(
    (SELECT score FROM grogu_match_candidates('tester', NULL, ideal) WHERE pt_id = pt)
      > (SELECT score FROM grogu_match_candidates('tester', NULL, ideal) WHERE pt_id = pt_any),
    'the invited, well-matched playtest outranks the generic one');
  PERFORM pg_temp.assert(doc ->> 'source' = 'rules' AND (doc ->> 'stale')::boolean, 'tester side starts rule-ordered and stale');
  PERFORM pg_temp.assert((grogu_playtest_recommendations_prepare(ideal) -> 'tester') ? 'experience'
                         AND grogu_playtest_recommendations_prepare(ideal)::text NOT ILIKE '%Ideal Match%',
                         'tester-side model input has the profile but no name');

  BEGIN
    PERFORM grogu_playtest_invite(other, pt, okay);
    RAISE EXCEPTION 'FAIL: another studio sent an invite';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_invite(dev, pt, applied);
    RAISE EXCEPTION 'FAIL: invited a tester who already applied';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_invite(dev, pt_draft, ideal);
    RAISE EXCEPTION 'FAIL: invited to a draft';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
  BEGIN
    PERFORM grogu_playtest_invite(dev, pt, other);
    RAISE EXCEPTION 'FAIL: invited a studio account';
  EXCEPTION WHEN SQLSTATE 'GR001' THEN NULL; END;

  -- The cap: 50 invites per playtest.
  FOR i IN 1..49 LOOP
    INSERT INTO playtest_invites (playtest_id, tester_user_id, invited_by)
    SELECT pt_any, u.id, dev FROM users u WHERE u.role = 'Player'
       AND NOT EXISTS (SELECT 1 FROM playtest_invites x WHERE x.playtest_id = pt_any AND x.tester_user_id = u.id)
     ORDER BY u.id LIMIT 1;
  END LOOP;
  SELECT count(*) INTO n FROM playtest_invites WHERE playtest_id = pt_any;
  IF n < 50 THEN
    -- Not enough testers in this database to reach the cap; top up with new ones.
    FOR i IN 1..(50 - n) LOOP
      PERFORM grogu_playtest_invite(dev, pt_any, pg_temp.tester('Cap Filler ' || i, '{}'::jsonb, 0));
    END LOOP;
  END IF;
  PERFORM pg_temp.assert((SELECT count(*) FROM playtest_invites WHERE playtest_id = pt_any) >= 50, 'reached the cap');
  BEGIN
    PERFORM grogu_playtest_invite(dev, pt_any, pg_temp.tester('One Too Many', '{}'::jsonb, 0));
    RAISE EXCEPTION 'FAIL: invited past the cap';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;
END
$t$;

ROLLBACK;
