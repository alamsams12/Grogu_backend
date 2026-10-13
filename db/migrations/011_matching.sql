-- 011_matching.sql
--
-- Phase 6 (parts B and C): matching testers and playtests.
--
--  * Studio side: for a recruiting playtest, the testers who fit it best.
--  * Tester side: the open playtests that fit a tester best.
--
-- One engine serves both (grogu_match_candidates). It works in two steps:
--
-- 1. Eligibility. Hard filters, the same in both directions. A tester is
--    eligible for a playtest only if the playtest is recruiting, open and not
--    full, the tester has not applied to it, has one of the required platforms,
--    speaks one of the required languages, and meets the minimum experience and
--    the minimum reputation. A studio's own requirements are never overridden.
--
-- 2. Score, 0 to 100: a weighted average of factors that are each 0 to 1. The
--    weights are rows in `matching_weights`, per side, so the ranking can be
--    tuned without a migration. A factor with weight 0 is ignored. Each result
--    carries up to three short reasons taken from its strongest factors.
--
--    Factors (see the seed rows below for the default weights):
--      genre        share of the playtest's wanted genres the tester plays
--      experience   how far above the minimum experience the tester is
--      reputation   the tester's level, 1 (Newcomer) to the top level
--      reliability  accepted tests the tester finished, with a prior so a new
--                   tester starts at 0.5 rather than 0 or 1
--      quality      the tester's reviews that studios approved, same prior
--      availability weekly hours against the playtest's estimated hours
--      levelFit     how close the playtest's reputation bar is to the tester's
--                   reputation (a selective playtest the tester qualifies for)
--      capacity     share of spots still open
--      reward       the playtest pays cash
--      invited      the studio invited this tester
--
-- AI (Gemini) never decides who is eligible. The API layer may send the top of
-- the rule-based list to Gemini, which may only re-order that list and add a
-- one-line reason per entry. That answer is cached in `match_ai_cache` against
-- a fingerprint of the list, and used only while the list is unchanged. With no
-- key, or when Gemini fails, the rule order is shown. Model input carries no
-- names, emails, bios or ids (the API layer replaces ids with c1, c2, ...).
--
-- Invitations: a studio may invite a suggested tester. The tester gets an
-- in-app notification, once per playtest, and invited playtests rank higher in
-- their recommendations.
--
-- Additive and idempotent.

BEGIN;

/* -------------------------------------------------------------------------- */
/*  Tables                                                                     */
/* -------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS matching_weights (
  context     varchar(16) NOT NULL,
  factor      varchar(32) NOT NULL,
  weight      integer     NOT NULL,
  description text        NOT NULL DEFAULT '',
  PRIMARY KEY (context, factor),
  CONSTRAINT matching_weights_context_check CHECK (context IN ('studio', 'tester')),
  CONSTRAINT matching_weights_weight_check  CHECK (weight >= 0)
);

-- Re-running never overwrites a tuned weight.
INSERT INTO matching_weights (context, factor, weight, description) VALUES
  ('studio', 'genre',        30, 'Plays the genres the playtest wants.'),
  ('studio', 'reputation',   20, 'Higher level testers rank higher.'),
  ('studio', 'reliability',  20, 'Finishes the tests they are accepted to.'),
  ('studio', 'quality',      10, 'Writes reviews studios approve.'),
  ('studio', 'availability', 10, 'Has the hours the playtest needs.'),
  ('studio', 'experience',   10, 'Experience above the playtest''s minimum.'),
  ('tester', 'genre',        35, 'Matches the tester''s favourite genres.'),
  ('tester', 'levelFit',     15, 'A selective playtest the tester qualifies for.'),
  ('tester', 'availability', 15, 'Fits the tester''s weekly hours.'),
  ('tester', 'capacity',     10, 'Plenty of spots left.'),
  ('tester', 'reward',        5, 'Pays a cash reward.'),
  ('tester', 'invited',      20, 'The studio invited this tester.')
ON CONFLICT (context, factor) DO NOTHING;

CREATE TABLE IF NOT EXISTS playtest_invites (
  id             serial PRIMARY KEY,
  playtest_id    integer     NOT NULL REFERENCES playtests(id) ON DELETE CASCADE,
  tester_user_id integer     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invited_by     integer     REFERENCES users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT playtest_invites_once UNIQUE (playtest_id, tester_user_id)
);

CREATE INDEX IF NOT EXISTS playtest_invites_tester_idx ON playtest_invites (tester_user_id);

-- One AI ranking per playtest (studio side) or per tester (tester side). Used
-- only while `fingerprint` matches the current rule-based shortlist.
CREATE TABLE IF NOT EXISTS match_ai_cache (
  kind         varchar(16) NOT NULL,
  subject_id   integer     NOT NULL,
  fingerprint  text        NOT NULL,
  ranking      jsonb       NOT NULL,
  model        text        NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kind, subject_id),
  CONSTRAINT match_ai_cache_kind_check CHECK (kind IN ('studio', 'tester'))
);

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD  CONSTRAINT notifications_type_check
  CHECK (type IN ('application-accepted', 'application-rejected', 'application-received',
                  'feedback-received', 'playtest-published', 'test-reminder', 'system',
                  'feedback-approved', 'feedback-rejected', 'game-key-sent',
                  'reputation-earned', 'level-up', 'playtest-invite'));

/* -------------------------------------------------------------------------- */
/*  Small helpers                                                              */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_experience_rank(p_level text) RETURNS integer
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(coalesce(p_level, 'casual'))
           WHEN 'casual'       THEN 0
           WHEN 'regular'      THEN 1
           WHEN 'hardcore'     THEN 2
           WHEN 'professional' THEN 3
           ELSE 0
         END;
$$;

-- "rpg" -> "RPG", "pc" -> "PC", "roguelike" -> "Roguelike".
CREATE OR REPLACE FUNCTION grogu_tag_label(p_tag text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(p_tag)
           WHEN 'rpg' THEN 'RPG'
           WHEN 'pc'  THEN 'PC'
           ELSE initcap(replace(p_tag, '-', ' '))
         END;
$$;

-- {a} -> "A"; {a,b} -> "A and B"; {a,b,c} -> "A, B and C". At most three.
CREATE OR REPLACE FUNCTION grogu_join_labels(p_tags text[]) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN cardinality(t.l) = 0 THEN ''
           WHEN cardinality(t.l) = 1 THEN t.l[1]
           ELSE array_to_string(t.l[1:cardinality(t.l) - 1], ', ') || ' and ' || t.l[cardinality(t.l)]
         END
    FROM (SELECT ARRAY(SELECT grogu_tag_label(x)
                         FROM unnest(coalesce(p_tags, '{}')) WITH ORDINALITY AS u(x, o)
                        ORDER BY o
                        LIMIT 3) AS l) t;
$$;

CREATE OR REPLACE FUNCTION grogu_plural(p_count integer, p_one text, p_many text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT p_count || ' ' || CASE WHEN p_count = 1 THEN p_one ELSE p_many END;
$$;

/* -------------------------------------------------------------------------- */
/*  The engine                                                                 */
/* -------------------------------------------------------------------------- */
-- Every eligible (tester, playtest) pair, scored for one side. Pass a playtest
-- id for the studio side, a tester's user id for the tester side, or both to
-- score one pair. Unordered; callers sort.

CREATE OR REPLACE FUNCTION grogu_match_candidates(
  p_context text, p_playtest_id integer, p_tester_user_id integer
) RETURNS TABLE (tester_id integer, pt_id integer, score integer, factors jsonb, reasons text[])
  LANGUAGE sql STABLE AS $$
  WITH
  weights AS (
    SELECT coalesce(jsonb_object_agg(m.factor, m.weight), '{}'::jsonb) AS w,
           greatest(coalesce(sum(m.weight), 0), 1)::numeric          AS total
      FROM matching_weights m
     WHERE m.context = p_context AND m.weight > 0
  ),
  top_level AS (
    SELECT greatest(coalesce(max(l.level), 1), 2) AS top FROM reputation_levels l
  ),
  open_playtests AS (
    SELECT p.id,
           p.max_testers,
           coalesce(p.cash_reward, 0) AS cash,
           coalesce(s.name, 'The studio') AS studio_name,
           ARRAY(SELECT jsonb_array_elements_text(coalesce(p.requirements_json -> 'platforms', '[]'::jsonb)))
             AS req_platforms,
           ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p.requirements_json -> 'languages', '[]'::jsonb)) AS x)
             AS req_languages,
           ARRAY(SELECT DISTINCT x FROM unnest(
                   ARRAY(SELECT jsonb_array_elements_text(coalesce(p.requirements_json -> 'preferredGenres', '[]'::jsonb)))
                   || coalesce(g.genres, '{}'::text[])) AS x)
             AS wanted_genres,
           grogu_experience_rank(p.requirements_json ->> 'minExperienceLevel') AS min_rank,
           CASE WHEN (p.requirements_json ->> 'minReputation') ~ '^\d+(\.\d+)?$'
                THEN (p.requirements_json ->> 'minReputation')::numeric ELSE 0 END AS min_rep,
           CASE WHEN (p.requirements_json ->> 'estimatedHours') ~ '^\d+(\.\d+)?$'
                THEN (p.requirements_json ->> 'estimatedHours')::numeric ELSE 0 END AS est_hours,
           (SELECT count(*) FROM applications a
             WHERE a.playtest_id = p.id AND a.status IN ('Selected', 'Completed'))::int AS taken
      FROM playtests p
      LEFT JOIN games g   ON g.id = p.game_id
      LEFT JOIN studios s ON s.id = p.studio_id
     WHERE p.status = 'recruiting'
       AND p.game_id IS NOT NULL
       AND (p.closes_at IS NULL OR p.closes_at > now())
       AND (p_playtest_id IS NULL OR p.id = p_playtest_id)
  ),
  testers AS (
    SELECT pl.user_id,
           pl.id AS player_id,
           grogu_split_csv(pl.platforms) AS platforms,
           grogu_split_csv(pl.genres) AS genres,
           ARRAY(SELECT lower(x) FROM unnest(coalesce(pl.languages, '{}'::text[])) AS x) AS languages,
           grogu_experience_rank(pl.experience) AS exp_rank,
           coalesce(pl.experience, 'casual') AS experience,
           pl.weekly_availability_hours AS hours,
           pl.reputation,
           grogu_level_of(pl.reputation) AS lvl,
           (SELECT l.title FROM reputation_levels l WHERE l.level = grogu_level_of(pl.reputation)) AS level_title,
           (SELECT count(*) FROM applications a
             WHERE a.player_id = pl.id AND a.status IN ('Selected', 'Completed'))::int AS accepted,
           (SELECT count(*) FROM test_progress tp
             WHERE tp.tester_user_id = pl.user_id AND tp.stage = 'completed')::int AS completed,
           (SELECT count(*) FROM feedback f
             WHERE f.player_id = pl.id AND f.review_status = 'approved')::int AS approved,
           (SELECT count(*) FROM feedback f
             WHERE f.player_id = pl.id AND f.review_status IN ('approved', 'rejected'))::int AS decided
      FROM players pl
      JOIN users u ON u.id = pl.user_id AND u.role = 'Player'
     WHERE p_tester_user_id IS NULL OR pl.user_id = p_tester_user_id
  ),
  pairs AS (
    SELECT t.*,
           o.id AS playtest_ref, o.max_testers, o.cash, o.studio_name, o.wanted_genres,
           o.min_rank, o.min_rep, o.est_hours, o.taken,
           ARRAY(SELECT x FROM unnest(t.platforms) AS x WHERE x = ANY (o.req_platforms) ORDER BY x) AS shared_platforms,
           ARRAY(SELECT x FROM unnest(t.genres) AS x WHERE x = ANY (o.wanted_genres) ORDER BY x)   AS shared_genres,
           EXISTS (SELECT 1 FROM playtest_invites i
                    WHERE i.playtest_id = o.id AND i.tester_user_id = t.user_id) AS invited
      FROM testers t
      JOIN open_playtests o ON o.taken < o.max_testers
     WHERE NOT EXISTS (SELECT 1 FROM applications a WHERE a.playtest_id = o.id AND a.player_id = t.player_id)
       AND (cardinality(o.req_platforms) = 0 OR t.platforms && o.req_platforms)
       AND (cardinality(o.req_languages) = 0 OR t.languages && o.req_languages)
       AND t.exp_rank  >= o.min_rank
       AND t.reputation >= o.min_rep
  ),
  factored AS (
    SELECT pr.*,
           jsonb_build_object(
             'genre',        CASE WHEN cardinality(pr.wanted_genres) = 0 THEN 0.5
                                  ELSE round(least(1, cardinality(pr.shared_genres)::numeric
                                                      / least(2, cardinality(pr.wanted_genres))), 3) END,
             'experience',   CASE WHEN pr.min_rank >= 3 THEN 1
                                  ELSE round((pr.exp_rank - pr.min_rank)::numeric / (3 - pr.min_rank), 3) END,
             'reputation',   round((pr.lvl - 1)::numeric / ((SELECT top FROM top_level) - 1), 3),
             'reliability',  round(least(1, (pr.completed + 1)::numeric / (pr.accepted + 2)), 3),
             'quality',      round((pr.approved + 1)::numeric / (pr.decided + 2), 3),
             'availability', CASE WHEN pr.est_hours <= 0 THEN 1
                                  ELSE round(least(1, pr.hours::numeric / pr.est_hours), 3) END,
             'levelFit',     CASE WHEN pr.min_rep <= 0 THEN 0
                                  ELSE round(least(1, pr.min_rep / greatest(pr.reputation, 1)), 3) END,
             'capacity',     round((pr.max_testers - pr.taken)::numeric / greatest(pr.max_testers, 1), 3),
             'reward',       CASE WHEN pr.cash > 0 THEN 1 ELSE 0 END,
             'invited',      CASE WHEN pr.invited THEN 1 ELSE 0 END
           ) AS f
      FROM pairs pr
  )
  SELECT fa.user_id,
         fa.playtest_ref,
         round(100 * (SELECT coalesce(sum((w.value)::numeric * (fa.f ->> w.key)::numeric), 0)
                        FROM weights ws, jsonb_each_text(ws.w) AS w)
                    / (SELECT total FROM weights))::int,
         fa.f,
         ARRAY(
           SELECT r.txt
             FROM (VALUES
               (coalesce((ws.w ->> 'genre')::numeric, 0) * (fa.f ->> 'genre')::numeric,
                CASE WHEN cardinality(fa.shared_genres) = 0 THEN NULL
                     WHEN p_context = 'studio' THEN 'Plays ' || grogu_join_labels(fa.shared_genres)
                     ELSE 'Matches your genres: ' || grogu_join_labels(fa.shared_genres) END),
               (0.01,
                CASE WHEN cardinality(fa.shared_platforms) = 0 THEN NULL
                     WHEN p_context = 'studio' THEN 'Tests on ' || grogu_join_labels(fa.shared_platforms)
                     ELSE 'Runs on your ' || grogu_join_labels(fa.shared_platforms) END),
               (coalesce((ws.w ->> 'experience')::numeric, 0) * (fa.f ->> 'experience')::numeric,
                CASE WHEN fa.exp_rank > fa.min_rank THEN initcap(fa.experience) || ' experience' END),
               (coalesce((ws.w ->> 'reputation')::numeric, 0) * (fa.f ->> 'reputation')::numeric,
                CASE WHEN fa.lvl >= 2
                     THEN 'Level ' || fa.lvl || ' · ' || coalesce(fa.level_title, '')
                          || ' (' || fa.reputation || ' reputation)' END),
               (coalesce((ws.w ->> 'reliability')::numeric, 0) * (fa.f ->> 'reliability')::numeric,
                -- Only a strength is a reason: no "Finished 0 of 2".
                CASE WHEN fa.completed >= 1 AND fa.accepted >= 1
                     THEN 'Finished ' || least(fa.completed, fa.accepted) || ' of '
                          || grogu_plural(fa.accepted, 'accepted test', 'accepted tests') END),
               (coalesce((ws.w ->> 'quality')::numeric, 0) * (fa.f ->> 'quality')::numeric,
                CASE WHEN fa.approved >= 1
                     THEN grogu_plural(fa.approved, 'review', 'reviews') || ' approved by studios' END),
               (coalesce((ws.w ->> 'availability')::numeric, 0) * (fa.f ->> 'availability')::numeric,
                CASE WHEN (fa.f ->> 'availability')::numeric < 1 THEN NULL
                     WHEN p_context = 'studio' THEN fa.hours || ' h a week to test'
                     WHEN fa.est_hours > 0
                     THEN 'About ' || trim_scale(fa.est_hours) || ' h, within your ' || fa.hours || ' h a week' END),
               (coalesce((ws.w ->> 'levelFit')::numeric, 0) * (fa.f ->> 'levelFit')::numeric,
                CASE WHEN fa.min_rep > 0
                     THEN 'Asks for ' || trim_scale(fa.min_rep) || '+ reputation; you have ' || fa.reputation END),
               (coalesce((ws.w ->> 'capacity')::numeric, 0) * (fa.f ->> 'capacity')::numeric,
                (fa.max_testers - fa.taken) || ' of ' || fa.max_testers || ' spots left'),
               (coalesce((ws.w ->> 'reward')::numeric, 0) * (fa.f ->> 'reward')::numeric,
                CASE WHEN fa.cash > 0 THEN 'Pays ' || grogu_rupees(fa.cash) END),
               (coalesce((ws.w ->> 'invited')::numeric, 0) * (fa.f ->> 'invited')::numeric,
                CASE WHEN fa.invited THEN 'Invited by ' || fa.studio_name END)
             ) AS r(contribution, txt)
            WHERE r.txt IS NOT NULL AND r.contribution > 0
            ORDER BY r.contribution DESC
            LIMIT 3)
    FROM factored fa, weights ws;
$$;

/* -------------------------------------------------------------------------- */
/*  Shortlists                                                                 */
/* -------------------------------------------------------------------------- */
-- The rule-ordered top of each side, and a fingerprint of it. The AI ranking is
-- stored against that fingerprint and only used while it still matches.

CREATE OR REPLACE FUNCTION grogu_tester_shortlist(p_playtest_id integer)
  RETURNS TABLE (tester_id integer, score integer, factors jsonb, reasons text[], rank_pos integer)
  LANGUAGE sql STABLE AS $$
  SELECT c.tester_id, c.score, c.factors, c.reasons,
         (row_number() OVER (ORDER BY c.score DESC, pl.reputation DESC, c.tester_id))::int
    FROM grogu_match_candidates('studio', p_playtest_id, NULL) c
    JOIN players pl ON pl.user_id = c.tester_id
   ORDER BY c.score DESC, pl.reputation DESC, c.tester_id
   LIMIT 10;
$$;

CREATE OR REPLACE FUNCTION grogu_playtest_shortlist(p_tester_user_id integer)
  RETURNS TABLE (pt_id integer, score integer, factors jsonb, reasons text[], rank_pos integer)
  LANGUAGE sql STABLE AS $$
  SELECT c.pt_id, c.score, c.factors, c.reasons,
         (row_number() OVER (ORDER BY c.score DESC, p.closes_at NULLS LAST, c.pt_id))::int
    FROM grogu_match_candidates('tester', NULL, p_tester_user_id) c
    JOIN playtests p ON p.id = c.pt_id
   ORDER BY c.score DESC, p.closes_at NULLS LAST, c.pt_id
   LIMIT 6;
$$;

CREATE OR REPLACE FUNCTION grogu_shortlist_fingerprint(p_kind text, p_ids integer[], p_scores integer[])
  RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT md5(p_kind || ':' || coalesce(array_to_string(p_ids, ','), '') || '|'
             || coalesce(array_to_string(p_scores, ','), ''));
$$;

-- Applies a cached AI ranking to a rule-ordered list of {id, ...} items:
-- AI order first (only ids that are in the list, each once), then any the AI
-- left out in rule order. Adds `aiReason`.
CREATE OR REPLACE FUNCTION grogu_apply_ai_ranking(p_items jsonb, p_ranking jsonb, p_id_key text)
  RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  WITH items AS (
    SELECT i.value AS item, i.ord AS rule_pos
      FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) WITH ORDINALITY AS i(value, ord)
  ),
  ranked AS (
    SELECT DISTINCT ON (r.value ->> 'id') r.value ->> 'id' AS id, r.value ->> 'reason' AS reason, r.ord AS ai_pos
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_ranking) = 'array' THEN p_ranking ELSE '[]'::jsonb END)
           WITH ORDINALITY AS r(value, ord)
     ORDER BY r.value ->> 'id', r.ord
  )
  SELECT coalesce(jsonb_agg(it.item || jsonb_build_object('aiReason', rk.reason)
                            ORDER BY rk.ai_pos NULLS LAST, it.rule_pos), '[]'::jsonb)
    FROM items it
    LEFT JOIN ranked rk ON rk.id = it.item ->> p_id_key;
$$;

/* -------------------------------------------------------------------------- */
/*  Studio side                                                                */
/* -------------------------------------------------------------------------- */

-- The suggestions document for the owning studio. Suggestions exist only while
-- the playtest is recruiting and has spots left (`open`).
CREATE OR REPLACE FUNCTION grogu_tester_suggestions_view(
  p_user_id integer, p_playtest_id integer, p_notice text, p_ai_enabled boolean
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p        playtests;
  c        match_ai_cache;
  v_items  jsonb;
  v_fp     text;
  v_count  integer;
  v_open   boolean;
  v_use    boolean;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);

  v_open := p.status = 'recruiting'
            AND (p.closes_at IS NULL OR p.closes_at > now())
            AND (SELECT count(*) FROM applications a
                  WHERE a.playtest_id = p.id AND a.status IN ('Selected', 'Completed')) < p.max_testers;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'testerId', s.tester_id::text,
           'score',    s.score,
           'reasons',  to_jsonb(s.reasons),
           'invited',  EXISTS (SELECT 1 FROM playtest_invites i
                                WHERE i.playtest_id = p.id AND i.tester_user_id = s.tester_id))
           ORDER BY s.rank_pos), '[]'::jsonb),
         grogu_shortlist_fingerprint('studio', array_agg(s.tester_id ORDER BY s.rank_pos),
                                     array_agg(s.score ORDER BY s.rank_pos))
    INTO v_items, v_fp
    FROM grogu_tester_shortlist(p.id) s;

  SELECT count(*) INTO v_count FROM grogu_match_candidates('studio', p.id, NULL);

  SELECT * INTO c FROM match_ai_cache WHERE kind = 'studio' AND subject_id = p.id;
  v_use := c.subject_id IS NOT NULL AND c.fingerprint = v_fp AND jsonb_array_length(v_items) > 0;

  RETURN jsonb_build_object(
    'id',            p.id::text,
    'playtestId',    p.id::text,
    'open',          v_open,
    'source',        CASE WHEN v_use THEN 'ai' ELSE 'rules' END,
    'aiEnabled',     coalesce(p_ai_enabled, false),
    'stale',         jsonb_array_length(v_items) > 0 AND NOT v_use,
    'generatedAt',   CASE WHEN v_use THEN grogu_iso(c.generated_at) END,
    'model',         CASE WHEN v_use THEN c.model END,
    'notice',        nullif(btrim(coalesce(p_notice, '')), ''),
    'eligibleCount', v_count,
    'suggestions',   CASE WHEN v_use
                          THEN grogu_apply_ai_ranking(v_items, c.ranking, 'testerId')
                          ELSE (SELECT coalesce(jsonb_agg(x.value || '{"aiReason": null}'::jsonb ORDER BY x.ord), '[]'::jsonb)
                                  FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(value, ord)) END);
END;
$$;

-- What the API layer sends to the model for the studio side. Real ids are
-- returned for mapping; the API layer replaces them with c1, c2, ... before
-- anything leaves the server.
CREATE OR REPLACE FUNCTION grogu_tester_suggestions_prepare(p_user_id integer, p_playtest_id integer)
  RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p      playtests;
  g      games;
  v_doc  jsonb;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);
  SELECT * INTO g FROM games WHERE id = p.game_id;

  SELECT jsonb_build_object(
           'fingerprint', grogu_shortlist_fingerprint('studio', array_agg(s.tester_id ORDER BY s.rank_pos),
                                                      array_agg(s.score ORDER BY s.rank_pos)),
           'candidates', coalesce(jsonb_agg(jsonb_build_object(
               'id',              s.tester_id::text,
               'ruleScore',       s.score,
               'ruleReasons',     to_jsonb(s.reasons),
               'experience',      coalesce(pl.experience, 'casual'),
               'platforms',       to_jsonb(grogu_split_csv(pl.platforms)),
               'genres',          to_jsonb(grogu_split_csv(pl.genres)),
               'languages',       to_jsonb(pl.languages),
               'weeklyHours',     pl.weekly_availability_hours,
               'level',           grogu_level_of(pl.reputation),
               'reputation',      pl.reputation,
               'acceptedTests',   (SELECT count(*) FROM applications a WHERE a.player_id = pl.id AND a.status IN ('Selected', 'Completed')),
               'completedTests',  (SELECT count(*) FROM test_progress tp WHERE tp.tester_user_id = pl.user_id AND tp.stage = 'completed'),
               'approvedReviews', (SELECT count(*) FROM feedback f WHERE f.player_id = pl.id AND f.review_status = 'approved'))
             ORDER BY s.rank_pos), '[]'::jsonb))
    INTO v_doc
    FROM grogu_tester_shortlist(p.id) s
    JOIN players pl ON pl.user_id = s.tester_id;

  RETURN v_doc || jsonb_build_object(
    'stale', jsonb_array_length(v_doc -> 'candidates') > 0
             AND NOT EXISTS (SELECT 1 FROM match_ai_cache m
                              WHERE m.kind = 'studio' AND m.subject_id = p.id
                                AND m.fingerprint = v_doc ->> 'fingerprint'),
    'playtest', jsonb_build_object(
      'title',        coalesce(p.title, p.game_name),
      'game',         coalesce(g.title, p.game_name),
      'summary',      left(coalesce(p.summary, ''), 600),
      'goals',        to_jsonb(coalesce(p.goals, '{}')),
      'focusAreas',   to_jsonb(coalesce(p.focus_areas, '{}')),
      'genres',       to_jsonb(coalesce(g.genres, '{}')),
      'requirements', p.requirements_json));
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Tester side                                                                */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_playtest_recommendations_view(
  p_user_id integer, p_notice text, p_ai_enabled boolean
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  c        match_ai_cache;
  v_items  jsonb;
  v_fp     text;
  v_count  integer;
  v_use    boolean;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'tester');

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'playtestId', s.pt_id::text,
           'score',      s.score,
           'reasons',    to_jsonb(s.reasons),
           'invited',    EXISTS (SELECT 1 FROM playtest_invites i
                                  WHERE i.playtest_id = s.pt_id AND i.tester_user_id = p_user_id))
           ORDER BY s.rank_pos), '[]'::jsonb),
         grogu_shortlist_fingerprint('tester', array_agg(s.pt_id ORDER BY s.rank_pos),
                                     array_agg(s.score ORDER BY s.rank_pos))
    INTO v_items, v_fp
    FROM grogu_playtest_shortlist(p_user_id) s;

  SELECT count(*) INTO v_count FROM grogu_match_candidates('tester', NULL, p_user_id);

  SELECT * INTO c FROM match_ai_cache WHERE kind = 'tester' AND subject_id = p_user_id;
  v_use := c.subject_id IS NOT NULL AND c.fingerprint = v_fp AND jsonb_array_length(v_items) > 0;

  RETURN jsonb_build_object(
    'id',              p_user_id::text,
    'testerId',        p_user_id::text,
    'source',          CASE WHEN v_use THEN 'ai' ELSE 'rules' END,
    'aiEnabled',       coalesce(p_ai_enabled, false),
    'stale',           jsonb_array_length(v_items) > 0 AND NOT v_use,
    'generatedAt',     CASE WHEN v_use THEN grogu_iso(c.generated_at) END,
    'model',           CASE WHEN v_use THEN c.model END,
    'notice',          nullif(btrim(coalesce(p_notice, '')), ''),
    'eligibleCount',   v_count,
    'recommendations', CASE WHEN v_use
                            THEN grogu_apply_ai_ranking(v_items, c.ranking, 'playtestId')
                            ELSE (SELECT coalesce(jsonb_agg(x.value || '{"aiReason": null}'::jsonb ORDER BY x.ord), '[]'::jsonb)
                                    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(value, ord)) END);
END;
$$;

CREATE OR REPLACE FUNCTION grogu_playtest_recommendations_prepare(p_user_id integer)
  RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  pl    players;
  v_doc jsonb;
BEGIN
  PERFORM grogu_require_role(p_user_id, 'tester');
  SELECT * INTO pl FROM players WHERE user_id = p_user_id;

  SELECT jsonb_build_object(
           'fingerprint', grogu_shortlist_fingerprint('tester', array_agg(s.pt_id ORDER BY s.rank_pos),
                                                      array_agg(s.score ORDER BY s.rank_pos)),
           'candidates', coalesce(jsonb_agg(jsonb_build_object(
               'id',             s.pt_id::text,
               'ruleScore',      s.score,
               'ruleReasons',    to_jsonb(s.reasons),
               'title',          coalesce(p.title, p.game_name),
               'game',           coalesce(g.title, p.game_name),
               'summary',        left(coalesce(p.summary, ''), 400),
               'goals',          to_jsonb(coalesce(p.goals, '{}')),
               'focusAreas',     to_jsonb(coalesce(p.focus_areas, '{}')),
               'genres',         to_jsonb(coalesce(g.genres, '{}')),
               'platforms',      coalesce(p.requirements_json -> 'platforms', '[]'::jsonb),
               'estimatedHours', p.requirements_json -> 'estimatedHours',
               'ndaRequired',    p.requirements_json -> 'ndaRequired',
               'reward',         left(coalesce(p.reward, ''), 120),
               'cashReward',     p.cash_reward,
               'spotsLeft',      p.max_testers - (SELECT count(*) FROM applications a
                                                   WHERE a.playtest_id = p.id AND a.status IN ('Selected', 'Completed')),
               'invited',        EXISTS (SELECT 1 FROM playtest_invites i
                                          WHERE i.playtest_id = p.id AND i.tester_user_id = p_user_id))
             ORDER BY s.rank_pos), '[]'::jsonb))
    INTO v_doc
    FROM grogu_playtest_shortlist(p_user_id) s
    JOIN playtests p ON p.id = s.pt_id
    LEFT JOIN games g ON g.id = p.game_id;

  RETURN v_doc || jsonb_build_object(
    'stale', jsonb_array_length(v_doc -> 'candidates') > 0
             AND NOT EXISTS (SELECT 1 FROM match_ai_cache m
                              WHERE m.kind = 'tester' AND m.subject_id = p_user_id
                                AND m.fingerprint = v_doc ->> 'fingerprint'),
    'tester', jsonb_build_object(
      'experience',  coalesce(pl.experience, 'casual'),
      'platforms',   to_jsonb(grogu_split_csv(pl.platforms)),
      'genres',      to_jsonb(grogu_split_csv(pl.genres)),
      'languages',   to_jsonb(coalesce(pl.languages, '{}')),
      'weeklyHours', pl.weekly_availability_hours,
      'level',       grogu_level_of(coalesce(pl.reputation, 0)),
      'reputation',  coalesce(pl.reputation, 0)));
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Storing an AI ranking                                                      */
/* -------------------------------------------------------------------------- */
-- `p_ranking`: [{ "id": "<real id>", "reason": "..." }] best first. Stored
-- against the fingerprint the caller read BEFORE asking the model, so a list
-- that changed meanwhile is not dressed up with a stale ranking.

CREATE OR REPLACE FUNCTION grogu_match_store(
  p_user_id integer, p_kind text, p_subject_id integer, p_fingerprint text,
  p_ranking jsonb, p_model text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_clean jsonb;
BEGIN
  IF p_kind = 'studio' THEN
    PERFORM grogu_insight_playtest(p_user_id, p_subject_id);
  ELSIF p_kind = 'tester' THEN
    PERFORM grogu_require_role(p_user_id, 'tester');
    IF p_subject_id IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'You can only rank your own recommendations.' USING ERRCODE = 'GR004';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown ranking kind.' USING ERRCODE = 'GR005';
  END IF;

  IF coalesce(btrim(p_fingerprint), '') = '' THEN
    RAISE EXCEPTION 'A ranking needs the list it was made from.' USING ERRCODE = 'GR005';
  END IF;
  IF jsonb_typeof(p_ranking) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'The ranking has the wrong shape.' USING ERRCODE = 'GR005';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'reason', nullif(left(btrim(coalesce(t.reason, '')), 160), '')) ORDER BY t.ord), '[]'::jsonb)
    INTO v_clean
    FROM (
      SELECT DISTINCT ON (e.value ->> 'id') e.value ->> 'id' AS id,
             CASE WHEN jsonb_typeof(e.value -> 'reason') = 'string' THEN e.value ->> 'reason' END AS reason,
             e.ord
        FROM jsonb_array_elements(p_ranking) WITH ORDINALITY AS e(value, ord)
       WHERE jsonb_typeof(e.value) = 'object'
         AND (e.value ->> 'id') ~ '^\d{1,9}$'
       ORDER BY e.value ->> 'id', e.ord
    ) t
   WHERE t.ord <= 20;

  IF jsonb_array_length(v_clean) = 0 THEN
    RAISE EXCEPTION 'The ranking was empty.' USING ERRCODE = 'GR005';
  END IF;

  INSERT INTO match_ai_cache (kind, subject_id, fingerprint, ranking, model, generated_at)
  VALUES (p_kind, p_subject_id, p_fingerprint, v_clean,
          left(coalesce(nullif(btrim(p_model), ''), 'unknown'), 80), now())
  ON CONFLICT (kind, subject_id) DO UPDATE SET
    fingerprint  = excluded.fingerprint,
    ranking      = excluded.ranking,
    model        = excluded.model,
    generated_at = excluded.generated_at;

  RETURN v_clean;
END;
$$;

/* -------------------------------------------------------------------------- */
/*  Invitations                                                                */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION grogu_playtest_invite(
  p_user_id integer, p_playtest_id integer, p_tester_user_id integer
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  p        playtests;
  v_id     integer;
  v_studio text;
BEGIN
  p := grogu_insight_playtest(p_user_id, p_playtest_id);

  IF p.status <> 'recruiting' THEN
    RAISE EXCEPTION 'Invites can only be sent while the playtest is recruiting.' USING ERRCODE = 'GR003';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_tester_user_id AND role = 'Player') THEN
    RAISE EXCEPTION 'Tester not found.' USING ERRCODE = 'GR001';
  END IF;
  IF EXISTS (SELECT 1 FROM applications a JOIN players pl ON pl.id = a.player_id
              WHERE a.playtest_id = p.id AND pl.user_id = p_tester_user_id) THEN
    RAISE EXCEPTION 'This tester has already applied.' USING ERRCODE = 'GR003';
  END IF;

  -- Serialise invites for one playtest so the cap cannot be overshot.
  PERFORM 1 FROM playtests WHERE id = p.id FOR UPDATE;
  IF (SELECT count(*) FROM playtest_invites WHERE playtest_id = p.id) >= 50
     AND NOT EXISTS (SELECT 1 FROM playtest_invites WHERE playtest_id = p.id AND tester_user_id = p_tester_user_id) THEN
    RAISE EXCEPTION 'You can invite up to 50 testers to one playtest.' USING ERRCODE = 'GR003';
  END IF;

  INSERT INTO playtest_invites (playtest_id, tester_user_id, invited_by)
  VALUES (p.id, p_tester_user_id, p_user_id)
  ON CONFLICT (playtest_id, tester_user_id) DO NOTHING
  RETURNING id INTO v_id;

  -- Inviting twice is harmless and notifies once.
  IF v_id IS NOT NULL THEN
    SELECT coalesce(s.name, 'A studio') INTO v_studio FROM studios s WHERE s.id = p.studio_id;
    PERFORM grogu_notify(
      p_tester_user_id, 'playtest-invite',
      coalesce(v_studio, 'A studio') || ' invited you to ' || coalesce(p.title, p.game_name),
      'They think you would be a good fit. Have a look, and apply if it interests you.',
      '/playtests/' || p.id);
  END IF;

  RETURN jsonb_build_object('playtestId', p.id::text, 'testerId', p_tester_user_id::text, 'invited', true);
END;
$$;

COMMIT;
