-- 007_assets_and_playtest_access.sql
--
-- Phase 3: game posters, build delivery to accepted testers, and review media.
--
--  * games.cover_image_url (already a column) can now be set through
--    grogu_game_save.
--  * Playtests get install instructions and an access key next to build_url.
--    These are NOT part of the public playtest document: the base builder
--    grogu_playtest_json() now emits blanks, and grogu_playtest_view() adds the
--    real values only for the owning studio and for testers who have been
--    accepted. Before this migration, build_url was returned to every viewer of
--    GET /api/v1/bootstrap, anonymous visitors included.
--  * Feedback can carry up to six uploaded screenshots or recordings.
--  * grogu_playtest_access_save lets a studio correct the build link, install
--    notes or key after publishing; grogu_playtest_save only edits drafts.
--
-- Additive and idempotent. Existing /api/v1 response shapes are unchanged
-- except for the new fields (installInstructions, accessKey, media).

BEGIN;

ALTER TABLE playtests ADD COLUMN IF NOT EXISTS install_instructions text NOT NULL DEFAULT '';
ALTER TABLE playtests ADD COLUMN IF NOT EXISTS access_key           text NOT NULL DEFAULT '';
ALTER TABLE feedback  ADD COLUMN IF NOT EXISTS media                jsonb NOT NULL DEFAULT '[]'::jsonb;

-- build_url used to be free text. Keep the invariant "empty or an http(s) link"
-- that grogu_build_url() now enforces, without failing on legacy rows.
UPDATE playtests
   SET build_url = ''
 WHERE build_url <> '' AND build_url !~* '^https?://';

CREATE OR REPLACE FUNCTION grogu_playtest_json(p playtests) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',          p.id::text,
    'gameId',      p.game_id::text,
    'developerId', (SELECT s.user_id::text FROM studios s WHERE s.id = p.studio_id),
    'title',       coalesce(p.title, p.game_name),
    'summary',     p.summary,
    'goals',       to_jsonb(p.goals),
    'focusAreas',  to_jsonb(p.focus_areas),
    'status',      p.status,
    'requirements',p.requirements_json,
    'tasks',       coalesce((
                     SELECT jsonb_agg(jsonb_build_object(
                              'id',               t.id::text,
                              'title',            t.title,
                              'description',      t.description,
                              'type',             t.type,
                              'required',         t.required,
                              'estimatedMinutes', t.estimated_minutes
                            ) ORDER BY t.position, t.id)
                       FROM playtest_tasks t WHERE t.playtest_id = p.id), '[]'::jsonb),
    'reward',      p.reward,
    'cashReward',  p.cash_reward,
    'maxTesters',  p.max_testers,
    -- Denormalised counters the frontend reads straight off the playtest.
    'acceptedTesters', (SELECT count(*) FROM applications a
                         WHERE a.playtest_id = p.id AND a.status IN ('Selected', 'Completed')),
    'applicantCount',  (SELECT count(*) FROM applications a
                         WHERE a.playtest_id = p.id AND a.status <> 'Withdrawn'),
    -- Access details are not part of the public document. grogu_playtest_view()
    -- adds the real values for the owning studio and accepted testers only.
    'buildUrl',            '',
    'installInstructions', '',
    'accessKey',           '',
    'opensAt',     grogu_iso(p.opens_at),
    'closesAt',    grogu_iso(p.closes_at),
    'createdAt',   grogu_iso(p.created_at)
  );
$$;

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
    'submittedAt',     grogu_iso(f.created_at)
  );
$$;

/* -------------------------------------------------------------------------- */
/*  Validators                                                                 */
/* -------------------------------------------------------------------------- */

-- An image link for a poster: a file uploaded to Grogu, or an https URL.
-- Anything else (javascript:, data:, relative paths) is refused.
CREATE OR REPLACE FUNCTION grogu_asset_url(p_url text) RETURNS text
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text := nullif(btrim(coalesce(p_url, '')), '');
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;
  IF length(v) > 2000 THEN
    RAISE EXCEPTION 'That image link is too long.' USING ERRCODE = 'GR005';
  END IF;
  IF (v ~ '^/uploads/[A-Za-z0-9._-]+$' AND v !~ '\.\.') OR v ~* '^https://[^[:space:]]+$' THEN
    RETURN v;
  END IF;
  RAISE EXCEPTION 'That image link is not allowed.' USING ERRCODE = 'GR005';
END;
$$;

-- A build link: empty, or an http(s) URL.
CREATE OR REPLACE FUNCTION grogu_build_url(p_url text) RETURNS text
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text := btrim(coalesce(p_url, ''));
BEGIN
  IF v = '' THEN
    RETURN '';
  END IF;
  IF length(v) > 2000 OR v !~* '^https?://[^[:space:]]+$' THEN
    RAISE EXCEPTION 'Enter a valid http(s) link for the build.' USING ERRCODE = 'GR005';
  END IF;
  RETURN v;
END;
$$;

-- Review attachments: up to six files uploaded to Grogu, each an image or video.
-- Only /uploads/ paths are accepted, so a review cannot embed an arbitrary
-- remote image (tracking pixels, hotlinks) in a studio's dashboard.
CREATE OR REPLACE FUNCTION grogu_media_json(p_media jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  m      jsonb;
  v_out  jsonb := '[]'::jsonb;
  v_url  text;
  v_kind text;
BEGIN
  IF p_media IS NULL OR jsonb_typeof(p_media) = 'null' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_media) <> 'array' THEN
    RAISE EXCEPTION 'Attachments must be a list.' USING ERRCODE = 'GR005';
  END IF;
  IF jsonb_array_length(p_media) > 6 THEN
    RAISE EXCEPTION 'You can attach up to 6 files.' USING ERRCODE = 'GR005';
  END IF;

  FOR m IN SELECT value FROM jsonb_array_elements(p_media) LOOP
    v_url  := m ->> 'url';
    v_kind := m ->> 'kind';

    IF v_url IS NULL OR v_url !~ '^/uploads/[A-Za-z0-9._-]+$' OR v_url ~ '\.\.' THEN
      RAISE EXCEPTION 'Attachments must be files uploaded to Grogu.' USING ERRCODE = 'GR005';
    END IF;
    IF v_kind IS NULL OR v_kind NOT IN ('image', 'video') THEN
      RAISE EXCEPTION 'Each attachment must be an image or a video.' USING ERRCODE = 'GR005';
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'url',  v_url,
      'kind', v_kind,
      'name', left(coalesce(m ->> 'name', ''), 120)));
  END LOOP;

  RETURN v_out;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Playtest access                                                            */
/* -------------------------------------------------------------------------- */

-- The playtest document as one viewer may see it. The build link, install notes
-- and access key are included only for the owning studio and for testers who
-- have been accepted; everyone else gets the blanks from grogu_playtest_json().
CREATE OR REPLACE FUNCTION grogu_playtest_view(p playtests, p_viewer_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT grogu_playtest_json(p) || CASE
    WHEN p_viewer_id IS NOT NULL AND (
         EXISTS (SELECT 1 FROM studios s
                  WHERE s.id = p.studio_id AND s.user_id = p_viewer_id)
      OR EXISTS (SELECT 1 FROM applications a
                   JOIN players pl ON pl.id = a.player_id
                  WHERE a.playtest_id = p.id
                    AND pl.user_id = p_viewer_id
                    AND a.status IN ('Selected', 'Completed'))
    )
    THEN jsonb_build_object(
           'buildUrl',            p.build_url,
           'installInstructions', p.install_instructions,
           'accessKey',           p.access_key)
    ELSE '{}'::jsonb
  END;
$$;

-- Lets the owning studio change how testers get the game at any point before the
-- playtest is archived. Partial: only the keys present in the body are written.
CREATE OR REPLACE FUNCTION grogu_playtest_access_save(
  p_user_id integer, p_playtest_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p        playtests;
  v_studio integer;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  v_studio := grogu_studio_id(p_user_id);

  SELECT * INTO p FROM playtests WHERE id = p_playtest_id AND studio_id = v_studio;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
  END IF;
  IF p.status = 'archived' THEN
    RAISE EXCEPTION 'An archived playtest cannot be edited.' USING ERRCODE = 'GR003';
  END IF;

  UPDATE playtests SET
    build_url = CASE WHEN p_input ? 'buildUrl'
                     THEN grogu_build_url(p_input ->> 'buildUrl') ELSE build_url END,
    install_instructions = CASE WHEN p_input ? 'installInstructions'
                     THEN coalesce(p_input ->> 'installInstructions', '') ELSE install_instructions END,
    access_key = CASE WHEN p_input ? 'accessKey'
                     THEN coalesce(p_input ->> 'accessKey', '') ELSE access_key END
   WHERE id = p.id
  RETURNING * INTO p;

  RETURN grogu_playtest_view(p, p_user_id);
END;
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
  ) INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION grogu_game_save(
  p_user_id integer, p_game_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE g games;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  IF coalesce(trim(p_input ->> 'title'), '') = '' THEN
    RAISE EXCEPTION 'Give the game a title.' USING ERRCODE = 'GR005';
  END IF;

  IF p_game_id IS NULL THEN
    INSERT INTO games (developer_user_id, title, tagline, description, genres, platforms,
                       status, accent_hue, build_version, cover_image_url)
    VALUES (
      p_user_id,
      trim(p_input ->> 'title'),
      coalesce(p_input ->> 'tagline', ''),
      coalesce(p_input ->> 'description', ''),
      grogu_jsonb_text_array(p_input -> 'genres'),
      grogu_jsonb_text_array(p_input -> 'platforms'),
      coalesce(p_input ->> 'status', 'in-development'),
      coalesce((p_input ->> 'accentHue')::int, 210),
      coalesce(p_input ->> 'buildVersion', '0.1.0'),
      grogu_asset_url(p_input ->> 'coverImageUrl')
    )
    RETURNING * INTO g;
  ELSE
    UPDATE games SET
      title         = trim(p_input ->> 'title'),
      tagline       = coalesce(p_input ->> 'tagline', ''),
      description   = coalesce(p_input ->> 'description', ''),
      genres        = grogu_jsonb_text_array(p_input -> 'genres'),
      platforms     = grogu_jsonb_text_array(p_input -> 'platforms'),
      status        = coalesce(p_input ->> 'status', 'in-development'),
      accent_hue    = coalesce((p_input ->> 'accentHue')::int, 210),
      build_version = coalesce(p_input ->> 'buildVersion', '0.1.0'),
      -- Only touched when the key is present, so saving other fields never clears a poster.
      cover_image_url = CASE WHEN p_input ? 'coverImageUrl'
                             THEN grogu_asset_url(p_input ->> 'coverImageUrl')
                             ELSE cover_image_url END,
      updated_at    = now()
     WHERE id = p_game_id AND developer_user_id = p_user_id
    RETURNING * INTO g;

    IF g.id IS NULL THEN
      RAISE EXCEPTION 'Game not found.' USING ERRCODE = 'GR001';
    END IF;
  END IF;

  RETURN grogu_game_json(g);
END;
$$;

CREATE OR REPLACE FUNCTION grogu_playtest_save(
  p_user_id integer, p_playtest_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p          playtests;
  g          games;
  v_studio   integer;
  v_status   text;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  v_studio := grogu_studio_id(p_user_id);

  SELECT * INTO g FROM games
   WHERE id = nullif(p_input ->> 'gameId', '')::int AND developer_user_id = p_user_id;
  IF g.id IS NULL THEN
    RAISE EXCEPTION 'Pick one of your games.' USING ERRCODE = 'GR005';
  END IF;

  IF coalesce(trim(p_input ->> 'title'), '') = '' THEN
    RAISE EXCEPTION 'Give the playtest a title.' USING ERRCODE = 'GR005';
  END IF;
  IF coalesce((p_input ->> 'maxTesters')::int, 0) < 1 THEN
    RAISE EXCEPTION 'A playtest needs at least one tester.' USING ERRCODE = 'GR005';
  END IF;

  IF p_playtest_id IS NULL THEN
    v_status := CASE WHEN coalesce((p_input ->> 'publish')::boolean, false)
                     THEN 'recruiting' ELSE 'draft' END;

    INSERT INTO playtests (
      studio_id, game_id, title, summary, goals, focus_areas, status, requirements_json,
      reward, cash_reward, max_testers, build_url, install_instructions, access_key, opens_at, closes_at,
      -- legacy columns, kept populated so `/api/playtests/*` still works
      game_name, genre, platform, requirements, target_players
    ) VALUES (
      v_studio, g.id,
      trim(p_input ->> 'title'),
      coalesce(p_input ->> 'summary', ''),
      grogu_jsonb_text_array(p_input -> 'goals'),
      grogu_jsonb_text_array(p_input -> 'focusAreas'),
      v_status,
      grogu_requirements_json(p_input -> 'requirements', g.id),
      coalesce(p_input ->> 'reward', ''),
      nullif(p_input ->> 'cashReward', '')::int,
      (p_input ->> 'maxTesters')::int,
      grogu_build_url(p_input ->> 'buildUrl'),
      coalesce(p_input ->> 'installInstructions', ''),
      coalesce(p_input ->> 'accessKey', ''),
      now(),
      nullif(p_input ->> 'closesAt', '')::timestamptz,
      g.title,
      coalesce(array_to_string(g.genres, ', '), ''),
      coalesce(array_to_string(g.platforms, ', '), ''),
      coalesce(p_input ->> 'summary', ''),
      (p_input ->> 'maxTesters')::int
    )
    RETURNING * INTO p;

    IF v_status = 'recruiting' THEN
      PERFORM grogu_notify(
        p_user_id, 'playtest-published', p.title || ' is live',
        'Your playtest is now visible on Discover and open for applications.',
        '/developer/playtests/' || p.id);
    END IF;
  ELSE
    SELECT * INTO p FROM playtests WHERE id = p_playtest_id AND studio_id = v_studio;
    IF p.id IS NULL THEN
      RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
    END IF;
    IF p.status <> 'draft' THEN
      RAISE EXCEPTION 'Only draft playtests can be edited.' USING ERRCODE = 'GR003';
    END IF;

    UPDATE playtests SET
      game_id           = g.id,
      title             = trim(p_input ->> 'title'),
      summary           = coalesce(p_input ->> 'summary', ''),
      goals             = grogu_jsonb_text_array(p_input -> 'goals'),
      focus_areas       = grogu_jsonb_text_array(p_input -> 'focusAreas'),
      requirements_json = grogu_requirements_json(p_input -> 'requirements', g.id),
      reward            = coalesce(p_input ->> 'reward', ''),
      cash_reward       = nullif(p_input ->> 'cashReward', '')::int,
      max_testers       = (p_input ->> 'maxTesters')::int,
      build_url         = grogu_build_url(p_input ->> 'buildUrl'),
      install_instructions = coalesce(p_input ->> 'installInstructions', ''),
      access_key        = coalesce(p_input ->> 'accessKey', ''),
      closes_at         = nullif(p_input ->> 'closesAt', '')::timestamptz,
      game_name         = g.title,
      genre             = coalesce(array_to_string(g.genres, ', '), ''),
      platform          = coalesce(array_to_string(g.platforms, ', '), ''),
      target_players    = (p_input ->> 'maxTesters')::int
     WHERE id = p_playtest_id
    RETURNING * INTO p;
  END IF;

  PERFORM grogu_sync_tasks(p.id, p_input -> 'tasks');

  SELECT * INTO p FROM playtests WHERE id = p.id;
  RETURN grogu_playtest_view(p, p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION grogu_playtest_set_status(
  p_user_id integer, p_playtest_id integer, p_status text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p        playtests;
  v_studio integer;
  v_ok     boolean;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  v_studio := grogu_studio_id(p_user_id);

  SELECT * INTO p FROM playtests WHERE id = p_playtest_id AND studio_id = v_studio;
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
  END IF;

  -- Same transition table as PLAYTEST_STATUS_TRANSITIONS in `lib/domain.ts`.
  v_ok := CASE p.status
            WHEN 'draft'       THEN p_status = 'recruiting'
            WHEN 'recruiting'  THEN p_status IN ('in-progress', 'closed')
            WHEN 'in-progress' THEN p_status IN ('review', 'closed')
            WHEN 'review'      THEN p_status IN ('completed', 'closed')
            WHEN 'completed'   THEN p_status = 'archived'
            WHEN 'closed'      THEN p_status = 'archived'
            ELSE false
          END;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'A % playtest cannot move to %.', p.status, p_status USING ERRCODE = 'GR003';
  END IF;

  UPDATE playtests SET status = p_status WHERE id = p.id RETURNING * INTO p;

  IF p_status = 'recruiting' THEN
    PERFORM grogu_notify(
      p_user_id, 'playtest-published', p.title || ' is live',
      'Your playtest is now visible on Discover and open for applications.',
      '/developer/playtests/' || p.id);
  END IF;

  RETURN grogu_playtest_view(p, p_user_id);
END;
$$;

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

COMMIT;
