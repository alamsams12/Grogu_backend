-- Signup and login behave as the frontend expects. Rolls back; leaves no data.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

DO $t$
DECLARE
  u jsonb;
  hash text;
BEGIN
  u := grogu_signup('{"role":"tester","name":"Test Tester","email":"t1@test.invalid","password":"secret1","experienceLevel":"regular","platforms":["pc"],"preferredGenres":["rpg"]}');
  PERFORM pg_temp.assert(u ->> 'role' = 'tester', 'signup returns the tester role');
  PERFORM pg_temp.assert(u ->> 'email' = 't1@test.invalid', 'viewer sees their own email');

  SELECT password INTO hash FROM users WHERE email = 't1@test.invalid';
  PERFORM pg_temp.assert(hash LIKE '$2%', 'password is stored as a bcrypt hash');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM players p JOIN users x ON x.id = p.user_id WHERE x.email = 't1@test.invalid'),
                         'signup creates the players row');

  u := grogu_signup('{"role":"developer","name":"Test Dev","email":"d1@test.invalid","password":"secret1","studioName":"Test Studio","studioSize":"small"}');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM studios s JOIN users x ON x.id = s.user_id WHERE x.email = 'd1@test.invalid' AND s.name = 'Test Studio'),
                         'signup creates the studios row with the studio name');

  -- duplicate email -> GR003 (conflict)
  BEGIN
    PERFORM grogu_signup('{"role":"tester","name":"Again","email":"T1@test.invalid","password":"secret1"}');
    RAISE EXCEPTION 'FAIL: duplicate email was accepted';
  EXCEPTION WHEN SQLSTATE 'GR003' THEN NULL; END;

  -- short password -> GR005 (validation)
  BEGIN
    PERFORM grogu_signup('{"role":"tester","name":"Short","email":"s@test.invalid","password":"123"}');
    RAISE EXCEPTION 'FAIL: short password was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- login: right password works, wrong one is rejected
  PERFORM pg_temp.assert(grogu_login('t1@test.invalid', 'secret1') ->> 'role' = 'tester', 'login with the right password');
  BEGIN
    PERFORM grogu_login('t1@test.invalid', 'wrong');
    RAISE EXCEPTION 'FAIL: wrong password was accepted';
  EXCEPTION WHEN SQLSTATE 'GR002' THEN NULL; END;
END
$t$;

ROLLBACK;
