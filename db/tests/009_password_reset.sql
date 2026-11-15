-- Forgot password: request, single use, expiry, rate limits. Rolls back.
BEGIN;

CREATE FUNCTION pg_temp.assert(cond boolean, msg text) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

DO $t$
DECLARE
  uid integer;
  res jsonb;
  h1  text := repeat('a', 64);
  h2  text := repeat('b', 64);
  i   integer;
BEGIN
  uid := (grogu_signup('{"role":"tester","name":"Reset Me","email":"reset@test.invalid","password":"oldpass123"}') ->> 'id')::int;

  res := grogu_password_reset_request('nobody@test.invalid', h1, 'ip1');
  PERFORM pg_temp.assert(NOT (res ->> 'send')::boolean, 'an unknown email sends nothing');

  res := grogu_password_reset_request('RESET@test.invalid', h1, 'ip1');
  PERFORM pg_temp.assert((res ->> 'send')::boolean AND res ->> 'email' = 'reset@test.invalid', 'a known email (any case) gets a link');

  -- A newer request replaces the older link.
  PERFORM grogu_password_reset_request('reset@test.invalid', h2, 'ip1');
  BEGIN
    PERFORM grogu_password_reset_complete(h1, 'newpass123');
    RAISE EXCEPTION 'FAIL: a replaced link still worked';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  BEGIN
    PERFORM grogu_password_reset_complete(h2, 'short');
    RAISE EXCEPTION 'FAIL: a short password was accepted';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  res := grogu_password_reset_complete(upper(h2), 'newpass123');
  PERFORM pg_temp.assert((res ->> 'userId')::int = uid, 'the reset names the user');
  PERFORM pg_temp.assert(grogu_login('reset@test.invalid', 'newpass123') ->> 'id' = uid::text, 'the new password works');
  BEGIN
    PERFORM grogu_login('reset@test.invalid', 'oldpass123');
    RAISE EXCEPTION 'FAIL: the old password still worked';
  EXCEPTION WHEN SQLSTATE 'GR002' THEN NULL; END;
  PERFORM pg_temp.assert(grogu_password_changed_epoch(uid) > 0, 'the change time is recorded');

  BEGIN
    PERFORM grogu_password_reset_complete(h2, 'another123');
    RAISE EXCEPTION 'FAIL: a link worked twice';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- Expired links fail.
  PERFORM grogu_password_reset_request('reset@test.invalid', repeat('c', 64), 'ip2');
  UPDATE password_reset_tokens SET expires_at = now() - interval '1 minute' WHERE token_hash = repeat('c', 64);
  BEGIN
    PERFORM grogu_password_reset_complete(repeat('c', 64), 'another123');
    RAISE EXCEPTION 'FAIL: an expired link worked';
  EXCEPTION WHEN SQLSTATE 'GR005' THEN NULL; END;

  -- Three requests an hour per account (three were made above).
  res := grogu_password_reset_request('reset@test.invalid', repeat('d', 64), 'ip3');
  PERFORM pg_temp.assert(NOT (res ->> 'send')::boolean AND res ->> 'reason' = 'user-limit', 'the per-account limit applies');

  -- Ten links an hour per IP hash, across accounts (stops mass emailing).
  FOR i IN 1..10 LOOP
    IF i % 3 = 1 THEN
      PERFORM grogu_signup(jsonb_build_object('role', 'tester', 'name', 'Flood ' || i,
                'email', 'flood' || i || '@test.invalid', 'password', 'secret123'));
    END IF;
    res := grogu_password_reset_request('flood' || (i - (i - 1) % 3) || '@test.invalid', md5(i::text) || md5('x' || i), 'ip-flood');
    PERFORM pg_temp.assert((res ->> 'send')::boolean, 'link ' || i || ' from one IP is sent');
  END LOOP;
  res := grogu_password_reset_request('reset@test.invalid', repeat('e', 64), 'ip-flood');
  PERFORM pg_temp.assert(res ->> 'reason' = 'ip-limit', 'the per-IP limit applies');
END
$t$;

ROLLBACK;
