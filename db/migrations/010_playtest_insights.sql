-- 010_playtest_insights.sql
--
-- Phase 6 (part A): a summary of a playtest's feedback for the studio -- the
-- overall picture, top highlights, what testers like and dislike, the bugs
-- they hit, and suggested next steps.
--
-- Two sources, one shape:
--
--  * "ai"    -- written by Gemini in the API layer and cached here, one row per
--               playtest. It is regenerated only when feedback has arrived since
--               it was written, which keeps the free tier within its limits.
--  * "rules" -- computed on read, in SQL, from the feedback itself (counts of
--               the most repeated highlights, pain points and bugs). It is what
--               a studio sees when Gemini is switched off, rate-limited or down,
--               and before the first AI summary exists. It never fails.
--
-- Sentiment counts always come from the feedback rows, never from the model.
--
-- What leaves the database for Gemini (grogu_insight_inputs): ratings, the
-- sentiment label, and the review text, truncated. No tester ids, names or
-- emails. Review text is untrusted: the API layer instructs the model to treat
-- it as data, and everything the model returns is validated by
-- grogu_insight_clean() before it is stored.
--
-- Additive and idempotent. Nothing here changes an existing response.

BEGIN;

CREATE TABLE IF NOT EXISTS playtest_insights (
  playtest_id      integer     PRIMARY KEY REFERENCES playtests(id) ON DELETE CASCADE,
  -- The feedback this summary was written from. If either differs from the
  -- playtest's current feedback, the summary is stale.
  feedback_count   integer     NOT NULL,
  last_feedback_id integer     NOT NULL,
  content          jsonb       NOT NULL,
  model            text        NOT NULL,
  generated_at     timestamptz NOT NULL DEFAULT now()
);

/* -------------------------------------------------------------------------- */
/*  Small helpers                                                              */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_mentions_label(p_count integer) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT p_count || CASE WHEN p_count = 1 THEN ' tester' ELSE ' testers' END;
$$;

-- jsonb array of strings -> at most p_max trimmed, non-empty strings of at most
-- p_len characters, in order. Anything that is not a string is dropped.
CREATE OR REPLACE FUNCTION grogu_insight_texts(p jsonb, p_max integer, p_len integer) RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(t.v) ORDER BY t.ord), '[]'::jsonb)
    FROM (
      SELECT left(btrim(e.value #>> '{}'), p_len) AS v, e.ord
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END)
             WITH ORDINALITY AS e(value, ord)
       WHERE jsonb_typeof(e.value) = 'string'
         AND btrim(e.value #>> '{}') <> ''
       ORDER BY e.ord
       LIMIT p_max
    ) t;
$$;

-- jsonb array of {text, mentions} -> at most p_max entries with trimmed text of
-- at most 220 characters and mentions between 1 and p_cap (a theme cannot be
-- raised by more reviews than exist).
CREATE OR REPLACE FUNCTION grogu_insight_clean_points(p jsonb, p_max integer, p_cap integer) RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('text', t.text, 'mentions', t.m) ORDER BY t.ord), '[]'::jsonb)
    FROM (
      SELECT left(btrim(e.value ->> 'text'), 220) AS text,
             greatest(1, least(greatest(p_cap, 1)::numeric,
               CASE WHEN jsonb_typeof(e.value -> 'mentions') = 'number'
                    THEN round((e.value ->> 'mentions')::numeric) ELSE 1 END))::int AS m,
             e.ord
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END)
             WITH ORDINALITY AS e(value, ord)
       WHERE jsonb_typeof(e.value) = 'object'
         AND jsonb_typeof(e.value -> 'text') = 'string'
         AND btrim(e.value ->> 'text') <> ''
       ORDER BY e.ord
       LIMIT p_max
    ) t;
$$;

-- The one place that decides what a stored summary may contain.
CREATE OR REPLACE FUNCTION grogu_insight_clean(p_content jsonb, p_cap integer) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_content IS NULL OR jsonb_typeof(p_content) <> 'object' THEN
    RAISE EXCEPTION 'The summary has the wrong shape.' USING ERRCODE = 'GR005';
  END IF;

  RETURN jsonb_build_object(
    'summary',    left(btrim(coalesce(
                    CASE WHEN jsonb_typeof(p_content -> 'summary') = 'string'
                         THEN p_content ->> 'summary' END, '')), 700),
    'highlights', grogu_insight_texts(p_content -> 'highlights', 5, 220),
    'likes',      grogu_insight_clean_points(p_content -> 'likes', 5, p_cap),
    'dislikes',   grogu_insight_clean_points(p_content -> 'dislikes', 5, p_cap),
    'bugs',       grogu_insight_clean_points(p_content -> 'bugs', 5, p_cap),
    'actions',    grogu_insight_texts(p_content -> 'actions', 4, 220));
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Reading the feedback                                                       */
/* -------------------------------------------------------------------------- */

-- Counts that never come from a model. sentimentLabel: "positive" or "negative"
-- when more than half of the reviews are, "mixed" when both appear without a
-- majority, "neutral" otherwise, "none" with no feedback.
CREATE OR REPLACE FUNCTION grogu_insight_stats(p_playtest_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'feedbackCount',  t.n,
    'lastFeedbackId', t.last_id,
    'sentiment',      jsonb_build_object('positive', t.pos, 'neutral', t.neu, 'negative', t.neg),
    'sentimentLabel', CASE
                        WHEN t.n = 0         THEN 'none'
                        WHEN t.pos * 2 > t.n THEN 'positive'
                        WHEN t.neg * 2 > t.n THEN 'negative'
                        WHEN t.pos > 0 AND t.neg > 0 THEN 'mixed'
                        ELSE 'neutral'
                      END)
    FROM (
      SELECT count(*)::int AS n,
             coalesce(max(f.id), 0)::int AS last_id,
             (count(*) FILTER (WHERE f.sentiment = 'positive'))::int AS pos,
             (count(*) FILTER (WHERE f.sentiment = 'neutral'))::int  AS neu,
             (count(*) FILTER (WHERE f.sentiment = 'negative'))::int AS neg
        FROM feedback f
       WHERE f.playtest_id = p_playtest_id
    ) t;
$$;

-- The most repeated entries of one kind ('likes' = highlights, 'dislikes' =
-- pain points, 'bugs'), compared case-insensitively. "mentions" is the number
-- of different reviews that raised it, so one tester repeating themselves
-- counts once.
CREATE OR REPLACE FUNCTION grogu_insight_points(p_playtest_id integer, p_kind text) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('text', t.text, 'mentions', t.mentions)
                            ORDER BY t.mentions DESC, lower(t.text)), '[]'::jsonb)
    FROM (
      SELECT left((array_agg(x.item ORDER BY x.item))[1], 220) AS text,
             count(DISTINCT x.fid)::int AS mentions
        FROM (
          SELECT f.id AS fid, btrim(i) AS item
            FROM feedback f,
                 unnest(CASE p_kind WHEN 'likes'    THEN f.highlights
                                    WHEN 'dislikes' THEN f.pain_points
                                    ELSE f.bugs END) AS i
           WHERE f.playtest_id = p_playtest_id
             AND btrim(i) <> ''
        ) x
       GROUP BY lower(x.item)
       ORDER BY count(DISTINCT x.fid) DESC, lower(x.item)
       LIMIT 5
    ) t;
$$;

-- The no-AI summary. Same shape the AI summary is stored in.
CREATE OR REPLACE FUNCTION grogu_insight_rules(p_playtest_id integer) RETURNS jsonb
  LANGUAGE plpgsql STABLE AS $$
DECLARE
  s         jsonb := grogu_insight_stats(p_playtest_id);
  n         integer := (s ->> 'feedbackCount')::int;
  v_likes   jsonb := grogu_insight_points(p_playtest_id, 'likes');
  v_dislike jsonb := grogu_insight_points(p_playtest_id, 'dislikes');
  v_bugs    jsonb := grogu_insight_points(p_playtest_id, 'bugs');
  v_rate    integer;
  v_high    jsonb := '[]'::jsonb;
BEGIN
  IF n = 0 THEN
    RETURN jsonb_build_object(
      'summary', 'No feedback has come in yet.',
      'highlights', '[]'::jsonb, 'likes', '[]'::jsonb, 'dislikes', '[]'::jsonb,
      'bugs', '[]'::jsonb, 'actions', '[]'::jsonb);
  END IF;

  SELECT round(100.0 * count(*) FILTER (WHERE f.would_recommend) / count(*))::int
    INTO v_rate FROM feedback f WHERE f.playtest_id = p_playtest_id;

  IF jsonb_array_length(v_likes) > 0 THEN
    v_high := v_high || to_jsonb('Most praised: ' || (v_likes -> 0 ->> 'text')
      || ' (' || grogu_mentions_label((v_likes -> 0 ->> 'mentions')::int) || ').');
  END IF;
  IF jsonb_array_length(v_dislike) > 0 THEN
    v_high := v_high || to_jsonb('Most common complaint: ' || (v_dislike -> 0 ->> 'text')
      || ' (' || grogu_mentions_label((v_dislike -> 0 ->> 'mentions')::int) || ').');
  END IF;
  IF jsonb_array_length(v_bugs) > 0 THEN
    v_high := v_high || to_jsonb('Most reported bug: ' || (v_bugs -> 0 ->> 'text')
      || ' (' || grogu_mentions_label((v_bugs -> 0 ->> 'mentions')::int) || ').');
  END IF;

  RETURN jsonb_build_object(
    'summary', n || CASE WHEN n = 1 THEN ' tester has' ELSE ' testers have' END
               || ' reviewed this playtest: '
               || (s #>> '{sentiment,positive}') || ' positive, '
               || (s #>> '{sentiment,neutral}')  || ' neutral, '
               || (s #>> '{sentiment,negative}') || ' negative. '
               || v_rate || '% would recommend the build.',
    'highlights', v_high,
    'likes',      v_likes,
    'dislikes',   v_dislike,
    'bugs',       v_bugs,
    'actions',    '[]'::jsonb);
END;
$$;

-- Up to six entries of a text[], each cut to p_len characters.
CREATE OR REPLACE FUNCTION grogu_insight_clip(p_items text[], p_len integer) RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(left(btrim(s.x), p_len)) ORDER BY s.o), '[]'::jsonb)
    FROM (SELECT u.x, u.o
            FROM unnest(coalesce(p_items, '{}')) WITH ORDINALITY AS u(x, o)
           WHERE btrim(u.x) <> ''
           ORDER BY u.o
           LIMIT 6) s;
$$;

-- What the model reads: the 60 newest reviews, anonymised and truncated.
CREATE OR REPLACE FUNCTION grogu_insight_inputs(p_playtest_id integer) RETURNS jsonb
  LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'ratings', jsonb_build_object(
                        'fun', f.rating_fun, 'difficulty', f.rating_difficulty,
                        'clarity', f.rating_clarity, 'performance', f.rating_performance,
                        'polish', f.rating_polish),
           'sentiment',      f.sentiment,
           'summary',        left(f.summary, 600),
           'liked',          grogu_insight_clip(f.highlights, 160),
           'painPoints',     grogu_insight_clip(f.pain_points, 160),
           'bugs',           grogu_insight_clip(f.bugs, 160),
           'wouldRecommend', f.would_recommend,
           'hoursPlayed',    f.hours_played::float8) ORDER BY f.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM feedback WHERE playtest_id = p_playtest_id ORDER BY id DESC LIMIT 60) f;
$$;

-- A summary is stale when feedback exists and either no AI summary has been
-- written yet or feedback has arrived (or gone) since it was.
CREATE OR REPLACE FUNCTION grogu_insight_is_stale(p_playtest_id integer) RETURNS boolean
  LANGUAGE sql STABLE AS $$
  SELECT t.n > 0 AND (c.playtest_id IS NULL
                      OR c.feedback_count <> t.n
                      OR c.last_feedback_id <> t.last_id)
    FROM (SELECT count(*)::int AS n, coalesce(max(f.id), 0)::int AS last_id
            FROM feedback f WHERE f.playtest_id = p_playtest_id) t
    LEFT JOIN playtest_insights c ON c.playtest_id = p_playtest_id;
$$;

/* -------------------------------------------------------------------------- */
/*  API-facing functions                                                       */
/* -------------------------------------------------------------------------- */

-- Only the studio that owns the playtest may read or write its insights.
CREATE OR REPLACE FUNCTION grogu_insight_playtest(p_user_id integer, p_playtest_id integer)
  RETURNS playtests LANGUAGE plpgsql AS $$
DECLARE p playtests;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'developer');

  SELECT * INTO p FROM playtests
   WHERE id = p_playtest_id
     AND studio_id = (SELECT s.id FROM studios s WHERE s.user_id = p_user_id);
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'Playtest not found.' USING ERRCODE = 'GR001';
  END IF;

  RETURN p;
END;
$$;

-- The document the studio's screen renders. `p_notice` is a user-facing reason
-- why a fresh AI summary was not produced; `p_ai_enabled` says whether this
-- server can produce one at all.
--
-- source "ai": the cached AI summary (possibly stale, see `stale`).
-- source "rules": computed from the feedback now.
-- `feedbackCount` is how many reviews the shown summary covers; `totalFeedback`
-- is how many exist.
CREATE OR REPLACE FUNCTION grogu_insight_view(
  p_user_id integer, p_playtest_id integer, p_notice text, p_ai_enabled boolean
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p         playtests;
  s         jsonb;
  c         playtest_insights;
  v_total   integer;
  v_use     boolean;
  v_content jsonb;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);
  s := grogu_insight_stats(p.id);
  v_total := (s ->> 'feedbackCount')::int;

  SELECT * INTO c FROM playtest_insights WHERE playtest_id = p.id;
  v_use := c.playtest_id IS NOT NULL AND v_total > 0;
  v_content := CASE WHEN v_use THEN c.content ELSE grogu_insight_rules(p.id) END;

  RETURN jsonb_build_object(
    'id',             p.id::text,
    'playtestId',     p.id::text,
    'source',         CASE WHEN v_use THEN 'ai' ELSE 'rules' END,
    'aiEnabled',      coalesce(p_ai_enabled, false),
    'stale',          grogu_insight_is_stale(p.id),
    'feedbackCount',  CASE WHEN v_use THEN c.feedback_count ELSE v_total END,
    'totalFeedback',  v_total,
    'generatedAt',    CASE WHEN v_use THEN grogu_iso(c.generated_at) END,
    'model',          CASE WHEN v_use THEN c.model END,
    'notice',         nullif(btrim(coalesce(p_notice, '')), ''),
    'sentiment',      s -> 'sentiment',
    'sentimentLabel', s -> 'sentimentLabel') || v_content;
END;
$$;

-- Everything the API layer needs before it decides whether to call the model.
-- `inputs` is only filled when asked for and a new summary is actually needed.
CREATE OR REPLACE FUNCTION grogu_insight_prepare(
  p_user_id integer, p_playtest_id integer, p_with_inputs boolean
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p       playtests;
  g       games;
  s       jsonb;
  v_stale boolean;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);
  SELECT * INTO g FROM games WHERE id = p.game_id;
  s := grogu_insight_stats(p.id);
  v_stale := grogu_insight_is_stale(p.id);

  RETURN jsonb_build_object(
    'playtestId',     p.id,
    'title',          coalesce(p.title, p.game_name),
    'gameTitle',      coalesce(g.title, p.game_name),
    'genres',         to_jsonb(coalesce(g.genres, '{}'::text[])),
    'stale',          v_stale,
    'feedbackCount',  (s ->> 'feedbackCount')::int,
    'lastFeedbackId', (s ->> 'lastFeedbackId')::int,
    'inputs',         CASE WHEN coalesce(p_with_inputs, false) AND v_stale
                           THEN grogu_insight_inputs(p.id) ELSE '[]'::jsonb END);
END;
$$;

-- Saves an AI summary. `p_feedback_count` and `p_last_feedback_id` are what the
-- caller read BEFORE generating, not the current values: if a review arrived
-- while the model was working, the summary correctly stays stale. The content
-- is re-validated here whatever the caller already did to it.
CREATE OR REPLACE FUNCTION grogu_insight_store(
  p_user_id integer, p_playtest_id integer, p_content jsonb, p_model text,
  p_feedback_count integer, p_last_feedback_id integer
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p       playtests;
  v_clean jsonb;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);

  IF coalesce(p_feedback_count, 0) < 1 THEN
    RAISE EXCEPTION 'There is no feedback to summarise.' USING ERRCODE = 'GR005';
  END IF;

  v_clean := grogu_insight_clean(p_content, p_feedback_count);
  IF v_clean ->> 'summary' = '' THEN
    RAISE EXCEPTION 'The summary was empty.' USING ERRCODE = 'GR005';
  END IF;

  INSERT INTO playtest_insights (playtest_id, feedback_count, last_feedback_id, content, model, generated_at)
  VALUES (p.id, p_feedback_count, coalesce(p_last_feedback_id, 0), v_clean,
          left(coalesce(nullif(btrim(p_model), ''), 'unknown'), 80), now())
  ON CONFLICT (playtest_id) DO UPDATE SET
    feedback_count   = excluded.feedback_count,
    last_feedback_id = excluded.last_feedback_id,
    content          = excluded.content,
    model            = excluded.model,
    generated_at     = excluded.generated_at;

  RETURN v_clean;
END;
$$;

COMMIT;
