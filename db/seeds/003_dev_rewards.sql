-- 003_dev_rewards.sql
--
-- Development seed: game-key inventory and a few studio decisions on reviews,
-- so the reward screens have data. Run after 002_dev_games_and_playtests.sql.
--
-- DEV / STAGING ONLY. Decisions go through grogu_feedback_review, the function
-- the API calls, so reputation, ledger entries, key allocation and the
-- notifications are exactly what the app would produce.
--
--  * Every seeded game gets placeholder keys (DEV-<GAME>-NN), unless it
--    already has some.
--  * "The Long Harbour: accessibility pass" (completed): most reviews are
--    approved with cash, a key and sometimes a bonus; one is rejected.
--  * "Saltmarsh: narrative branch review": the demo tester's review is
--    approved, so priya.nair@example.com has a balance and a key on the way.
--  * "Tidepool Keeper: cozy loop" (the demo studio) is left untouched, so
--    mara@driftwoodgames.dev can approve and reject reviews herself.
--
-- Idempotent: keys are only added to games with none, and only reviews still
-- in "submitted" are decided.

BEGIN;

DO $seed$
DECLARE
  g        games;
  f        record;
  n        integer;
  v_prefix text;
BEGIN
  FOR g IN SELECT * FROM games
            WHERE developer_user_id IN (SELECT id FROM users WHERE email LIKE '%@example.com'
                                                            OR email = 'mara@driftwoodgames.dev')
  LOOP
    IF EXISTS (SELECT 1 FROM game_keys WHERE game_id = g.id) THEN
      CONTINUE;
    END IF;
    v_prefix := 'DEV-' || upper(left(regexp_replace(g.title, '[^A-Za-z0-9]', '', 'g'), 8)) || '-';
    PERFORM grogu_game_keys_add(g.developer_user_id, g.id, jsonb_build_object(
      'codes', (SELECT jsonb_agg(v_prefix || lpad(i::text, 2, '0') || '-' || upper(substr(md5(g.title || i), 1, 6)))
                  FROM generate_series(1, 8) i)));
  END LOOP;

  -- Long Harbour accessibility pass: approve all but the last review, reject it.
  n := 0;
  FOR f IN
    SELECT fb.id, s.user_id AS studio_user, p.cash_reward,
           count(*) OVER () AS total
      FROM feedback fb
      JOIN playtests p ON p.id = fb.playtest_id
      JOIN studios s ON s.id = p.studio_id
     WHERE p.title = 'The Long Harbour: accessibility pass'
       AND fb.review_status = 'submitted'
     ORDER BY fb.id
  LOOP
    n := n + 1;
    IF n = f.total AND f.total > 1 THEN
      PERFORM grogu_feedback_review(f.studio_user, f.id, jsonb_build_object(
        'decision', 'rejected',
        'note', 'Thanks for testing. This report did not cover the subtitle and colour options we asked about.'));
    ELSE
      PERFORM grogu_feedback_review(f.studio_user, f.id, jsonb_build_object(
        'decision', 'approved',
        'cashAmount', coalesce(f.cash_reward, 0),
        'gameKey', n % 2 = 1,
        'reputationBonus', CASE WHEN n % 3 = 0 THEN 10 ELSE 0 END,
        'note', CASE WHEN n % 3 = 0 THEN 'Really thorough notes on the menus. Thank you!' ELSE NULL END));
    END IF;
  END LOOP;

  -- The demo tester's Saltmarsh review.
  FOR f IN
    SELECT fb.id, s.user_id AS studio_user, p.cash_reward
      FROM feedback fb
      JOIN players pl ON pl.id = fb.player_id
      JOIN users u ON u.id = pl.user_id
      JOIN playtests p ON p.id = fb.playtest_id
      JOIN studios s ON s.id = p.studio_id
     WHERE u.email = 'priya.nair@example.com'
       AND p.title = 'Saltmarsh: narrative branch review'
       AND fb.review_status = 'submitted'
  LOOP
    PERFORM grogu_feedback_review(f.studio_user, f.id, jsonb_build_object(
      'decision', 'approved',
      'cashAmount', coalesce(f.cash_reward, 0),
      'gameKey', true,
      'reputationBonus', 15,
      'note', 'Your notes on the harbour-master scenes changed our script. Thank you.'));
  END LOOP;
END
$seed$;

COMMIT;
