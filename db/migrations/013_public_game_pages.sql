-- 013_public_game_pages.sql
--
-- Public game pages, bug reports and player reviews, plus a stronger signup
-- password rule.
--
--  * games.slug: a stable, URL-safe name for /games/<slug>. Generated once from
--    the title and never changed when the title changes, so the "Report a bug"
--    badge a studio puts in its game keeps working.
--  * games.links: optional public links (play in browser, store pages, a
--    download). These are public and separate from a playtest's private build
--    link, which stays visible to accepted testers only.
--  * game_bug_reports: anyone can report a bug from a game's page, signed in or
--    anonymously. Only the studio sees reports. When the studio confirms a
--    signed-in tester's report (confirmed, in progress or fixed), the tester
--    earns the "bug-confirmed" reputation once per report.
--  * game_reviews: a 1-5 rating with text, signed in or anonymous. A signed-in
--    user has one review per game and can edit it. Reviews from people who
--    submitted feedback in one of the game's playtests are marked verified.
--  * Abuse controls for anonymous submissions: the API passes a salted hash of
--    the caller's IP (never the IP itself), and these functions rate-limit on
--    it. The hash is never returned by any function.
--
-- Additive and idempotent. Existing response shapes only gain fields.

BEGIN;

/* -------------------------------------------------------------------------- */
/*  Signup: at least 8 characters                                              */
/* -------------------------------------------------------------------------- */
-- Same as 003 apart from the password length rule, which now matches the
-- frontend's strength check.

CREATE OR REPLACE FUNCTION grogu_signup(p_input jsonb) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  v_role_db  text;
  v_email    text := trim(p_input ->> 'email');
  v_name     text := trim(coalesce(p_input ->> 'name', ''));
  v_password text := coalesce(p_input ->> 'password', '');
  v_handle   text;
  v_suffix   integer := 0;
  u          users;
BEGIN
  v_role_db := grogu_role_to_db(p_input ->> 'role');
  IF v_role_db IS NULL THEN
    RAISE EXCEPTION 'Pick whether you are a tester or a developer.' USING ERRCODE = 'GR005';
  END IF;
  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Enter an email address.' USING ERRCODE = 'GR005';
  END IF;
  IF length(v_password) < 8 THEN
    RAISE EXCEPTION 'Password must be at least 8 characters.' USING ERRCODE = 'GR005';
  END IF;
  -- bcrypt only reads the first 72 bytes; anything far beyond that is a mistake.
  IF length(v_password) > 128 THEN
    RAISE EXCEPTION 'Password must be at most 128 characters.' USING ERRCODE = 'GR005';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'Enter your name.' USING ERRCODE = 'GR005';
  END IF;

  IF EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(v_email)) THEN
    RAISE EXCEPTION 'An account with that email already exists.' USING ERRCODE = 'GR003';
  END IF;

  v_handle := left(regexp_replace(lower(v_name), '[^a-z0-9]', '', 'g'), 16);
  IF v_handle = '' THEN v_handle := 'grogu'; END IF;
  WHILE EXISTS (
    SELECT 1 FROM users WHERE handle = v_handle || coalesce(nullif(v_suffix, 0)::text, '')
  ) LOOP
    v_suffix := v_suffix + 1;
  END LOOP;
  v_handle := v_handle || coalesce(nullif(v_suffix, 0)::text, '');

  INSERT INTO users (email, role, password, name, handle, location, bio)
  VALUES (
    v_email,
    v_role_db,
    crypt(v_password, gen_salt('bf', 10)),
    v_name,
    v_handle,
    left(coalesce(p_input ->> 'location', ''), 255),
    CASE WHEN v_role_db = 'Player'
         THEN 'New Grogu playtester.'
         ELSE coalesce(p_input ->> 'studioName', v_name) || ' on Grogu.' END
  )
  RETURNING * INTO u;

  IF v_role_db = 'Player' THEN
    INSERT INTO players (user_id, experience, platforms, genres, weekly_availability_hours)
    VALUES (
      u.id,
      coalesce(p_input ->> 'experienceLevel', 'casual'),
      array_to_string(grogu_jsonb_text_array(p_input -> 'platforms'), ','),
      array_to_string(grogu_jsonb_text_array(p_input -> 'preferredGenres'), ','),
      coalesce((p_input ->> 'weeklyAvailabilityHours')::int, 5)
    );
  ELSE
    INSERT INTO studios (user_id, name, website, studio_size)
    VALUES (
      u.id,
      coalesce(nullif(trim(coalesce(p_input ->> 'studioName', '')), ''), v_name),
      nullif(trim(coalesce(p_input ->> 'website', '')), ''),
      coalesce(p_input ->> 'studioSize', 'solo')
    );
  END IF;

  RETURN grogu_user_json(u, u.id);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Game slugs and public links                                                */
/* -------------------------------------------------------------------------- */

ALTER TABLE games ADD COLUMN IF NOT EXISTS slug  varchar(80);
ALTER TABLE games ADD COLUMN IF NOT EXISTS links jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION grogu_slugify(p_text text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(
    left(btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60),
  ''), 'game');
$$;

-- A slug no other game uses: the title's slug, then -2, -3, ...
CREATE OR REPLACE FUNCTION grogu_game_unique_slug(p_title text, p_game_id integer) RETURNS text
  LANGUAGE plpgsql AS $$
DECLARE
  v_base text := btrim(grogu_slugify(p_title), '-');
  v_slug text := v_base;
  v_n    integer := 1;
BEGIN
  WHILE EXISTS (SELECT 1 FROM games WHERE slug = v_slug AND id IS DISTINCT FROM p_game_id) LOOP
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  END LOOP;
  RETURN v_slug;
END;
$$;

DO $$
DECLARE g record;
BEGIN
  FOR g IN SELECT id, title FROM games WHERE slug IS NULL ORDER BY id LOOP
    UPDATE games SET slug = grogu_game_unique_slug(g.title, g.id) WHERE id = g.id;
  END LOOP;
END
$$;

ALTER TABLE games ALTER COLUMN slug SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS games_slug_key ON games (slug);

-- Validates and normalises the public links a studio enters. At most 8, each an
-- http(s) URL with a known kind and an optional short label.
CREATE OR REPLACE FUNCTION grogu_game_links(p_links jsonb) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  l       jsonb;
  v_out   jsonb := '[]'::jsonb;
  v_kind  text;
  v_url   text;
  v_label text;
BEGIN
  IF p_links IS NULL OR jsonb_typeof(p_links) = 'null' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_links) <> 'array' THEN
    RAISE EXCEPTION 'Links must be a list.' USING ERRCODE = 'GR005';
  END IF;
  IF jsonb_array_length(p_links) > 8 THEN
    RAISE EXCEPTION 'Add at most 8 links.' USING ERRCODE = 'GR005';
  END IF;

  FOR l IN SELECT value FROM jsonb_array_elements(p_links) LOOP
    v_kind  := l ->> 'kind';
    v_url   := btrim(coalesce(l ->> 'url', ''));
    v_label := left(btrim(coalesce(l ->> 'label', '')), 40);

    IF v_kind IS NULL OR v_kind NOT IN
       ('web-play', 'website', 'google-play', 'app-store', 'steam', 'itch', 'download', 'other') THEN
      RAISE EXCEPTION 'Each link needs a type.' USING ERRCODE = 'GR005';
    END IF;
    IF v_url = '' THEN
      CONTINUE;
    END IF;
    IF length(v_url) > 500 OR v_url !~* '^https?://[^[:space:]]+$' THEN
      RAISE EXCEPTION 'Links must be http(s) URLs.' USING ERRCODE = 'GR005';
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', v_kind, 'url', v_url, 'label', v_label));
  END LOOP;

  RETURN v_out;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Bug reports                                                                */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS game_bug_reports (
  id               serial PRIMARY KEY,
  game_id          integer      NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  -- NULL for anonymous reports.
  reporter_user_id integer      REFERENCES users(id) ON DELETE SET NULL,
  reporter_name    varchar(60)  NOT NULL DEFAULT '',
  contact_email    varchar(254),
  title            varchar(140) NOT NULL,
  description      text         NOT NULL,
  steps            text         NOT NULL DEFAULT '',
  severity         varchar(16)  NOT NULL DEFAULT 'medium',
  platform         varchar(160) NOT NULL DEFAULT '',
  build_version    varchar(64)  NOT NULL DEFAULT '',
  source           varchar(16)  NOT NULL DEFAULT 'page',
  media            jsonb        NOT NULL DEFAULT '[]'::jsonb,
  status           varchar(16)  NOT NULL DEFAULT 'new',
  duplicate_of     integer      REFERENCES game_bug_reports(id) ON DELETE SET NULL,
  developer_note   text         NOT NULL DEFAULT '',
  ip_hash          varchar(64),
  created_at       timestamptz  NOT NULL DEFAULT now(),
  updated_at       timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT game_bug_reports_severity_check CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  CONSTRAINT game_bug_reports_status_check
    CHECK (status IN ('new', 'confirmed', 'in-progress', 'fixed', 'wont-fix', 'duplicate')),
  CONSTRAINT game_bug_reports_source_check CHECK (source IN ('page', 'badge'))
);

CREATE INDEX IF NOT EXISTS game_bug_reports_game_idx     ON game_bug_reports (game_id, created_at DESC);
CREATE INDEX IF NOT EXISTS game_bug_reports_reporter_idx ON game_bug_reports (reporter_user_id) WHERE reporter_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS game_bug_reports_ip_idx       ON game_bug_reports (ip_hash, created_at) WHERE ip_hash IS NOT NULL;

/* -------------------------------------------------------------------------- */
/*  Reviews                                                                    */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS game_reviews (
  id              serial PRIMARY KEY,
  game_id         integer     NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  -- NULL for anonymous reviews.
  user_id         integer     REFERENCES users(id) ON DELETE SET NULL,
  author_name     varchar(40) NOT NULL DEFAULT '',
  rating          smallint    NOT NULL,
  body            text        NOT NULL,
  developer_reply text,
  replied_at      timestamptz,
  ip_hash         varchar(64),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT game_reviews_rating_check CHECK (rating BETWEEN 1 AND 5)
);

-- One review per signed-in user per game; anonymous reviews are rate-limited instead.
CREATE UNIQUE INDEX IF NOT EXISTS game_reviews_user_game_key ON game_reviews (game_id, user_id) WHERE user_id IS NOT NULL;
CREATE INDEX        IF NOT EXISTS game_reviews_game_idx      ON game_reviews (game_id, created_at DESC);
CREATE INDEX        IF NOT EXISTS game_reviews_ip_idx        ON game_reviews (ip_hash, created_at) WHERE ip_hash IS NOT NULL;

/* -------------------------------------------------------------------------- */
/*  Reputation rule and notification types                                     */
/* -------------------------------------------------------------------------- */

INSERT INTO reputation_rules (reason, amount, variable, max_amount, category, label, description, position) VALUES
  ('bug-confirmed', 10, false, NULL, 'review', 'Bug confirmed',
   'A studio confirmed a bug you reported from its game page.', 45)
ON CONFLICT (reason) DO NOTHING;

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD  CONSTRAINT notifications_type_check
  CHECK (type IN ('application-accepted', 'application-rejected', 'application-received',
                  'feedback-received', 'playtest-published', 'test-reminder', 'system',
                  'feedback-approved', 'feedback-rejected', 'game-key-sent',
                  'reputation-earned', 'level-up', 'playtest-invite',
                  'bug-reported', 'bug-status', 'review-received', 'review-reply'));

/* -------------------------------------------------------------------------- */
/*  JSON                                                                       */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_game_rating(p_game_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'average', coalesce(round(avg(r.rating)::numeric, 1), 0),
    'count',   count(*)
  ) FROM game_reviews r WHERE r.game_id = p_game_id;
$$;

CREATE OR REPLACE FUNCTION grogu_game_json(g games) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',            g.id::text,
    'developerId',   g.developer_user_id::text,
    'slug',          g.slug,
    'title',         g.title,
    'tagline',       g.tagline,
    'description',   g.description,
    'genres',        to_jsonb(g.genres),
    'platforms',     to_jsonb(g.platforms),
    'status',        g.status,
    'coverImageUrl', g.cover_image_url,
    'accentHue',     g.accent_hue,
    'buildVersion',  g.build_version,
    'links',         g.links,
    'rating',        grogu_game_rating(g.id),
    'updatedAt',     grogu_iso(g.updated_at)
  );
$$;

-- Whether a user submitted feedback in one of the game's playtests.
CREATE OR REPLACE FUNCTION grogu_game_tested_by(p_game_id integer, p_user_id integer) RETURNS boolean
  LANGUAGE sql STABLE AS $$
  SELECT p_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM feedback f
      JOIN players pl ON pl.id = f.player_id
      JOIN playtests p ON p.id = f.playtest_id
     WHERE p.game_id = p_game_id AND pl.user_id = p_user_id);
$$;

CREATE OR REPLACE FUNCTION grogu_game_review_json(r game_reviews) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',             r.id::text,
    'gameId',         r.game_id::text,
    'userId',         r.user_id::text,
    'authorName',     CASE WHEN r.user_id IS NOT NULL
                           THEN coalesce((SELECT u.name FROM users u WHERE u.id = r.user_id), 'Grogu player')
                           ELSE coalesce(nullif(r.author_name, ''), 'Anonymous player') END,
    'anonymous',      r.user_id IS NULL,
    'verified',       grogu_game_tested_by(r.game_id, r.user_id),
    'rating',         r.rating,
    'body',           r.body,
    'developerReply', r.developer_reply,
    'repliedAt',      grogu_iso(r.replied_at),
    'createdAt',      grogu_iso(r.created_at),
    'updatedAt',      grogu_iso(r.updated_at)
  );
$$;

-- p_owner: the studio's view, which adds the reporter's contact details.
CREATE OR REPLACE FUNCTION grogu_bug_report_json(b game_bug_reports, p_owner boolean) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'id',            b.id::text,
    'gameId',        b.game_id::text,
    'reporterId',    b.reporter_user_id::text,
    'reporterName',  CASE WHEN b.reporter_user_id IS NOT NULL
                          THEN coalesce((SELECT u.name FROM users u WHERE u.id = b.reporter_user_id), 'Grogu player')
                          ELSE coalesce(nullif(b.reporter_name, ''), 'Anonymous player') END,
    'anonymous',     b.reporter_user_id IS NULL,
    'title',         b.title,
    'description',   b.description,
    'steps',         b.steps,
    'severity',      b.severity,
    'platform',      b.platform,
    'buildVersion',  b.build_version,
    'source',        b.source,
    'media',         b.media,
    'status',        b.status,
    'duplicateOf',   b.duplicate_of::text,
    'developerNote', b.developer_note,
    'createdAt',     grogu_iso(b.created_at),
    'updatedAt',     grogu_iso(b.updated_at)
  ) || CASE WHEN p_owner THEN jsonb_build_object(
    'contactEmail',  coalesce(b.contact_email,
                              (SELECT u.email FROM users u WHERE u.id = b.reporter_user_id)),
    'reputationAwarded', coalesce((SELECT e.amount FROM reputation_events e
                                    WHERE e.reason = 'bug-confirmed' AND e.scope_key = b.id::text
                                    LIMIT 1), 0))
  ELSE '{}'::jsonb END;
$$;

/* -------------------------------------------------------------------------- */
/*  Saving a game                                                              */
/* -------------------------------------------------------------------------- */
-- Same as 007, plus the slug (set once, on create) and links (written only when
-- the key is present, like the cover image).

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
                       status, accent_hue, build_version, cover_image_url, slug, links)
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
      grogu_asset_url(p_input ->> 'coverImageUrl'),
      grogu_game_unique_slug(trim(p_input ->> 'title'), NULL),
      grogu_game_links(p_input -> 'links')
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
      cover_image_url = CASE WHEN p_input ? 'coverImageUrl'
                             THEN grogu_asset_url(p_input ->> 'coverImageUrl')
                             ELSE cover_image_url END,
      links         = CASE WHEN p_input ? 'links'
                           THEN grogu_game_links(p_input -> 'links')
                           ELSE links END,
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

/* -------------------------------------------------------------------------- */
/*  The public game page                                                       */
/* -------------------------------------------------------------------------- */
-- Everything /games/<slug> shows, as one viewer may see it. NULL (-> 404) for
-- an unknown slug. Bug reports are never public; a signed-in viewer sees only
-- the status of the reports they filed themselves.

CREATE OR REPLACE FUNCTION grogu_game_public(p_slug text, p_viewer_id integer) RETURNS jsonb
  LANGUAGE plpgsql STABLE AS $$
DECLARE
  g games;
  v_dist jsonb;
BEGIN
  SELECT * INTO g FROM games WHERE slug = lower(btrim(coalesce(p_slug, '')));
  IF g.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
           '1', count(*) FILTER (WHERE rating = 1), '2', count(*) FILTER (WHERE rating = 2),
           '3', count(*) FILTER (WHERE rating = 3), '4', count(*) FILTER (WHERE rating = 4),
           '5', count(*) FILTER (WHERE rating = 5))
    INTO v_dist FROM game_reviews WHERE game_id = g.id;

  RETURN jsonb_build_object(
    'game',      grogu_game_json(g),
    'developer', (SELECT grogu_user_json(u, p_viewer_id) FROM users u WHERE u.id = g.developer_user_id),
    'studio',    (SELECT grogu_developer_profile_json(s) FROM studios s WHERE s.user_id = g.developer_user_id),
    'ratingBreakdown', v_dist,
    'verifiedRating', (SELECT jsonb_build_object(
                                'average', coalesce(round(avg(r.rating)::numeric, 1), 0),
                                'count',   count(*))
                         FROM game_reviews r
                        WHERE r.game_id = g.id AND grogu_game_tested_by(g.id, r.user_id)),
    'reviews',   coalesce((SELECT jsonb_agg(grogu_game_review_json(r) ORDER BY r.created_at DESC, r.id DESC)
                             FROM (SELECT * FROM game_reviews WHERE game_id = g.id
                                    ORDER BY created_at DESC, id DESC LIMIT 50) r), '[]'::jsonb),
    'openPlaytests', coalesce((SELECT jsonb_agg(grogu_playtest_view(p, p_viewer_id) ORDER BY p.created_at DESC)
                                 FROM playtests p
                                WHERE p.game_id = g.id AND p.status IN ('recruiting', 'in-progress')), '[]'::jsonb),
    'bugsFixed', (SELECT count(*) FROM game_bug_reports b WHERE b.game_id = g.id AND b.status = 'fixed'),
    'viewerIsOwner', p_viewer_id IS NOT NULL AND p_viewer_id = g.developer_user_id,
    'viewerReview', (SELECT grogu_game_review_json(r) FROM game_reviews r
                      WHERE r.game_id = g.id AND p_viewer_id IS NOT NULL AND r.user_id = p_viewer_id),
    'viewerBugReports', coalesce((SELECT jsonb_agg(grogu_bug_report_json(b, false) ORDER BY b.created_at DESC)
                                    FROM game_bug_reports b
                                   WHERE b.game_id = g.id AND p_viewer_id IS NOT NULL
                                     AND b.reporter_user_id = p_viewer_id), '[]'::jsonb)
  );
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Filing a bug report                                                        */
/* -------------------------------------------------------------------------- */
-- p_viewer_id is NULL for anonymous reports. Anonymous reports carry no
-- attachments (uploads need an account) and are limited per IP hash.

CREATE OR REPLACE FUNCTION grogu_text_field(
  p_input jsonb, p_key text, p_min integer, p_max integer, p_label text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text := btrim(coalesce(p_input ->> p_key, ''));
BEGIN
  IF length(v) < p_min THEN
    IF p_min <= 1 THEN
      RAISE EXCEPTION '% is required.', p_label USING ERRCODE = 'GR005';
    END IF;
    RAISE EXCEPTION '% needs at least % characters.', p_label, p_min USING ERRCODE = 'GR005';
  END IF;
  IF length(v) > p_max THEN
    RAISE EXCEPTION '% can be at most % characters.', p_label, p_max USING ERRCODE = 'GR005';
  END IF;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION grogu_bug_report_create(
  p_viewer_id integer, p_slug text, p_input jsonb, p_ip_hash text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  g          games;
  b          game_bug_reports;
  v_email    text := nullif(btrim(coalesce(p_input ->> 'contactEmail', '')), '');
  v_severity text := lower(coalesce(p_input ->> 'severity', 'medium'));
  v_source   text := CASE WHEN p_input ->> 'source' = 'badge' THEN 'badge' ELSE 'page' END;
  v_media    jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO g FROM games WHERE slug = lower(btrim(coalesce(p_slug, '')));
  IF g.id IS NULL THEN
    RAISE EXCEPTION 'Game not found.' USING ERRCODE = 'GR001';
  END IF;

  -- Rate limits. Signed-in users by account, anonymous callers by IP hash.
  IF p_viewer_id IS NOT NULL THEN
    IF (SELECT count(*) FROM game_bug_reports
         WHERE reporter_user_id = p_viewer_id AND created_at > now() - interval '1 hour') >= 10 THEN
      RAISE EXCEPTION 'You have sent a lot of reports in the last hour. Please try again later.' USING ERRCODE = 'GR003';
    END IF;
  ELSE
    IF p_ip_hash IS NULL THEN
      RAISE EXCEPTION 'Sign in to report a bug.' USING ERRCODE = 'GR004';
    END IF;
    IF (SELECT count(*) FROM game_bug_reports
         WHERE ip_hash = p_ip_hash AND reporter_user_id IS NULL AND created_at > now() - interval '1 hour') >= 5
    OR (SELECT count(*) FROM game_bug_reports
         WHERE ip_hash = p_ip_hash AND reporter_user_id IS NULL AND created_at > now() - interval '1 day') >= 20 THEN
      RAISE EXCEPTION 'Too many reports from your network. Sign in, or try again later.' USING ERRCODE = 'GR003';
    END IF;
  END IF;

  IF v_severity NOT IN ('low', 'medium', 'high', 'critical') THEN
    RAISE EXCEPTION 'Pick a severity.' USING ERRCODE = 'GR005';
  END IF;
  IF v_email IS NOT NULL AND (length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN
    RAISE EXCEPTION 'Enter a valid email address, or leave it empty.' USING ERRCODE = 'GR005';
  END IF;
  IF p_viewer_id IS NOT NULL THEN
    v_media := grogu_media_json(p_input -> 'media');
  ELSIF jsonb_typeof(p_input -> 'media') = 'array' AND jsonb_array_length(p_input -> 'media') > 0 THEN
    RAISE EXCEPTION 'Sign in to attach screenshots.' USING ERRCODE = 'GR004';
  END IF;

  INSERT INTO game_bug_reports (game_id, reporter_user_id, reporter_name, contact_email, title, description,
                                steps, severity, platform, build_version, source, media, ip_hash)
  VALUES (
    g.id,
    p_viewer_id,
    CASE WHEN p_viewer_id IS NULL THEN left(btrim(coalesce(p_input ->> 'reporterName', '')), 60) ELSE '' END,
    -- A signed-in reporter is reached through their account.
    CASE WHEN p_viewer_id IS NULL THEN v_email ELSE NULL END,
    grogu_text_field(p_input, 'title', 5, 140, 'The title'),
    grogu_text_field(p_input, 'description', 15, 4000, 'The description'),
    grogu_text_field(p_input, 'steps', 0, 4000, 'Steps to reproduce'),
    v_severity,
    grogu_text_field(p_input, 'platform', 0, 160, 'Platform'),
    grogu_text_field(p_input, 'buildVersion', 0, 64, 'Build version'),
    v_source,
    v_media,
    p_ip_hash
  )
  RETURNING * INTO b;

  PERFORM grogu_notify(
    g.developer_user_id, 'bug-reported',
    CASE WHEN b.severity IN ('high', 'critical') THEN 'New ' || b.severity || ' bug in ' ELSE 'New bug report for ' END || g.title,
    b.title,
    '/developer/games/' || g.id || '/bugs');

  RETURN grogu_bug_report_json(b, false);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  The studio's bug inbox                                                     */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_game_bugs(p_user_id integer, p_game_id integer) RETURNS jsonb
  LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');
  IF NOT EXISTS (SELECT 1 FROM games WHERE id = p_game_id AND developer_user_id = p_user_id) THEN
    RAISE EXCEPTION 'Game not found.' USING ERRCODE = 'GR001';
  END IF;

  RETURN coalesce((SELECT jsonb_agg(grogu_bug_report_json(b, true) ORDER BY b.created_at DESC, b.id DESC)
                     FROM game_bug_reports b WHERE b.game_id = p_game_id), '[]'::jsonb);
END;
$$;

-- Changes a report's status and/or the studio's note. Confirming a signed-in
-- tester's report (confirmed, in progress or fixed) awards bug-confirmed once.
CREATE OR REPLACE FUNCTION grogu_bug_report_update(
  p_user_id integer, p_bug_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  b        game_bug_reports;
  g        games;
  v_status text;
  v_note   text;
  v_dup    integer;
  v_old    text;
  v_rep    integer := 0;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  SELECT b2.* INTO b
    FROM game_bug_reports b2
    JOIN games g2 ON g2.id = b2.game_id
   WHERE b2.id = p_bug_id AND g2.developer_user_id = p_user_id
     FOR UPDATE OF b2;
  IF b.id IS NULL THEN
    RAISE EXCEPTION 'Bug report not found.' USING ERRCODE = 'GR001';
  END IF;
  SELECT * INTO g FROM games WHERE id = b.game_id;

  v_old    := b.status;
  v_status := CASE WHEN p_input ? 'status' THEN lower(p_input ->> 'status') ELSE b.status END;
  v_note   := CASE WHEN p_input ? 'developerNote'
                   THEN grogu_text_field(p_input, 'developerNote', 0, 2000, 'The note')
                   ELSE b.developer_note END;

  IF v_status NOT IN ('new', 'confirmed', 'in-progress', 'fixed', 'wont-fix', 'duplicate') THEN
    RAISE EXCEPTION 'Unknown status.' USING ERRCODE = 'GR005';
  END IF;

  IF v_status = 'duplicate' AND nullif(p_input ->> 'duplicateOf', '') IS NOT NULL THEN
    v_dup := (p_input ->> 'duplicateOf')::int;
    IF v_dup = b.id OR NOT EXISTS (SELECT 1 FROM game_bug_reports WHERE id = v_dup AND game_id = b.game_id) THEN
      RAISE EXCEPTION 'Pick another report of this game as the original.' USING ERRCODE = 'GR005';
    END IF;
  ELSIF v_status = 'duplicate' THEN
    v_dup := b.duplicate_of;
  END IF;

  UPDATE game_bug_reports SET
    status         = v_status,
    developer_note = v_note,
    duplicate_of   = CASE WHEN v_status = 'duplicate' THEN v_dup ELSE NULL END,
    updated_at     = now()
   WHERE id = b.id
  RETURNING * INTO b;

  IF b.reporter_user_id IS NOT NULL AND v_status IN ('confirmed', 'in-progress', 'fixed') THEN
    v_rep := grogu_reputation_award(b.reporter_user_id, 'bug-confirmed', b.id::text, NULL,
                                    'Bug report: ' || left(b.title, 80), NULL, NULL, p_user_id);
  END IF;

  IF b.reporter_user_id IS NOT NULL AND v_status <> v_old THEN
    PERFORM grogu_notify(
      b.reporter_user_id, 'bug-status',
      CASE v_status
        WHEN 'confirmed'   THEN 'Your bug report for ' || g.title || ' was confirmed'
        WHEN 'in-progress' THEN g.title || ' is fixing a bug you reported'
        WHEN 'fixed'       THEN 'A bug you reported in ' || g.title || ' was fixed'
        WHEN 'wont-fix'    THEN 'Update on your bug report for ' || g.title
        WHEN 'duplicate'   THEN 'Your bug report for ' || g.title || ' was already known'
        ELSE 'Update on your bug report for ' || g.title END,
      '"' || left(b.title, 80) || '"'
        || CASE WHEN v_rep > 0 THEN ' You earned +' || v_rep || ' reputation.' ELSE '' END
        || CASE WHEN b.developer_note <> '' THEN ' Studio note: ' || left(b.developer_note, 200) ELSE '' END,
      '/games/' || g.slug);
  END IF;

  RETURN grogu_bug_report_json(b, true);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Reviews                                                                    */
/* -------------------------------------------------------------------------- */
-- Signed in: creates or updates the viewer's one review of the game.
-- Anonymous: creates a review, at most one per game per IP hash in 30 days and
-- five a day overall. The studio cannot review its own game.

CREATE OR REPLACE FUNCTION grogu_game_review_save(
  p_viewer_id integer, p_slug text, p_input jsonb, p_ip_hash text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  g        games;
  r        game_reviews;
  v_rating integer;
  v_body   text;
  v_new    boolean;
BEGIN
  SELECT * INTO g FROM games WHERE slug = lower(btrim(coalesce(p_slug, '')));
  IF g.id IS NULL THEN
    RAISE EXCEPTION 'Game not found.' USING ERRCODE = 'GR001';
  END IF;
  IF p_viewer_id IS NOT NULL AND p_viewer_id = g.developer_user_id THEN
    RAISE EXCEPTION 'You can''t review your own game.' USING ERRCODE = 'GR004';
  END IF;

  v_rating := grogu_int_field(p_input, 'rating', 0, 5, 'The rating');
  IF v_rating < 1 THEN
    RAISE EXCEPTION 'Pick a rating from 1 to 5 stars.' USING ERRCODE = 'GR005';
  END IF;
  v_body := grogu_text_field(p_input, 'body', 10, 2000, 'Your review');

  IF p_viewer_id IS NOT NULL THEN
    SELECT * INTO r FROM game_reviews WHERE game_id = g.id AND user_id = p_viewer_id FOR UPDATE;
    v_new := r.id IS NULL;
    IF v_new THEN
      INSERT INTO game_reviews (game_id, user_id, rating, body, ip_hash)
      VALUES (g.id, p_viewer_id, v_rating, v_body, p_ip_hash)
      RETURNING * INTO r;
    ELSE
      UPDATE game_reviews SET rating = v_rating, body = v_body, updated_at = now()
       WHERE id = r.id
      RETURNING * INTO r;
    END IF;
  ELSE
    IF p_ip_hash IS NULL THEN
      RAISE EXCEPTION 'Sign in to review this game.' USING ERRCODE = 'GR004';
    END IF;
    IF EXISTS (SELECT 1 FROM game_reviews
                WHERE game_id = g.id AND ip_hash = p_ip_hash AND user_id IS NULL
                  AND created_at > now() - interval '30 days') THEN
      RAISE EXCEPTION 'A review of this game was already sent from your network. Sign in to post or edit yours.'
        USING ERRCODE = 'GR003';
    END IF;
    IF (SELECT count(*) FROM game_reviews
         WHERE ip_hash = p_ip_hash AND user_id IS NULL AND created_at > now() - interval '1 day') >= 5 THEN
      RAISE EXCEPTION 'Too many reviews from your network today. Please try again tomorrow.' USING ERRCODE = 'GR003';
    END IF;

    v_new := true;
    INSERT INTO game_reviews (game_id, user_id, author_name, rating, body, ip_hash)
    VALUES (g.id, NULL, grogu_text_field(p_input, 'authorName', 0, 40, 'Your name'), v_rating, v_body, p_ip_hash)
    RETURNING * INTO r;
  END IF;

  IF v_new THEN
    PERFORM grogu_notify(
      g.developer_user_id, 'review-received',
      'New ' || v_rating || '-star review of ' || g.title,
      left(v_body, 160),
      '/developer/games/' || g.id || '/reviews');
  END IF;

  RETURN grogu_game_review_json(r);
END;
$$;

-- The studio's public reply to a review. An empty reply removes it.
CREATE OR REPLACE FUNCTION grogu_game_review_reply(
  p_user_id integer, p_review_id integer, p_input jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  r       game_reviews;
  g       games;
  v_reply text := grogu_text_field(p_input, 'reply', 0, 1500, 'The reply');
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  SELECT r2.* INTO r
    FROM game_reviews r2 JOIN games g2 ON g2.id = r2.game_id
   WHERE r2.id = p_review_id AND g2.developer_user_id = p_user_id
     FOR UPDATE OF r2;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'Review not found.' USING ERRCODE = 'GR001';
  END IF;
  SELECT * INTO g FROM games WHERE id = r.game_id;

  UPDATE game_reviews SET
    developer_reply = nullif(v_reply, ''),
    replied_at      = CASE WHEN v_reply = '' THEN NULL ELSE now() END
   WHERE id = r.id
  RETURNING * INTO r;

  IF r.user_id IS NOT NULL AND v_reply <> '' THEN
    PERFORM grogu_notify(
      r.user_id, 'review-reply',
      g.title || ' replied to your review',
      left(v_reply, 160),
      '/games/' || g.slug);
  END IF;

  RETURN grogu_game_review_json(r);
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Bootstrap: per-game counts for the studio                                  */
/* -------------------------------------------------------------------------- */
-- Same as 009 plus `gameActivity`: new/open bug counts per game, so the studio's
-- games list can show a badge without loading every report.

CREATE OR REPLACE FUNCTION grogu_bootstrap_extras(p_viewer_id integer, p_role text) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'gameKeys', CASE WHEN p_role = 'developer' THEN
      coalesce((SELECT jsonb_agg(grogu_game_key_json(k) ORDER BY k.game_id, k.id)
                  FROM game_keys k JOIN games g ON g.id = k.game_id
                 WHERE g.developer_user_id = p_viewer_id), '[]'::jsonb)
      ELSE '[]'::jsonb END,

    'ledgerEntries', coalesce((SELECT jsonb_agg(grogu_ledger_entry_json(l) ORDER BY l.created_at DESC, l.id DESC)
                                 FROM ledger_entries l WHERE l.user_id = p_viewer_id), '[]'::jsonb),

    'wallet', CASE WHEN p_role = 'tester' THEN jsonb_build_object(
      'balance', (SELECT coalesce(sum(l.amount), 0) FROM ledger_entries l WHERE l.user_id = p_viewer_id),
      'upiId',   coalesce((SELECT pl.upi_id FROM players pl WHERE pl.user_id = p_viewer_id), ''))
      ELSE NULL END,

    'reputationEvents', coalesce((SELECT jsonb_agg(grogu_reputation_event_json(e) ORDER BY e.created_at DESC, e.id DESC)
                                    FROM reputation_events e WHERE e.user_id = p_viewer_id), '[]'::jsonb),

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
                                    FROM reputation_levels l), '[]'::jsonb),

    'gameActivity', CASE WHEN p_role = 'developer' THEN
      coalesce((SELECT jsonb_agg(jsonb_build_object(
                         'gameId',   g.id::text,
                         'newBugs',  (SELECT count(*) FROM game_bug_reports b WHERE b.game_id = g.id AND b.status = 'new'),
                         'openBugs', (SELECT count(*) FROM game_bug_reports b
                                       WHERE b.game_id = g.id AND b.status IN ('new', 'confirmed', 'in-progress')),
                         'totalBugs',(SELECT count(*) FROM game_bug_reports b WHERE b.game_id = g.id)) ORDER BY g.id)
                  FROM games g WHERE g.developer_user_id = p_viewer_id), '[]'::jsonb)
      ELSE '[]'::jsonb END
  );
$$;

COMMIT;
