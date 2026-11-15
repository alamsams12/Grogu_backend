-- 015_password_reset.sql
--
-- Forgot password: a one-time link, emailed by the API.
--
--  * The API generates a random token, emails the link and stores only the
--    token's SHA-256 here, so a database leak doesn't hand out working links.
--  * A token works once, for 30 minutes. Asking again replaces any earlier
--    unused token. Requests are rate-limited per account and per IP hash.
--  * The request function answers the same way whether or not the email has an
--    account (the API always says "if that address has an account, we sent a
--    link"), so the form can't be used to discover who is registered.
--  * users.password_changed_at lets the API reject sessions issued before the
--    password changed, so a reset signs out every other device.
--
-- Additive and idempotent.

BEGIN;

ALTER TABLE users ADD COLUMN IF NOT EXISTS password_changed_at timestamptz;

CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id         serial PRIMARY KEY,
  user_id    integer     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash char(64)    NOT NULL,
  ip_hash    varchar(64),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT password_reset_tokens_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS password_reset_tokens_hash_key ON password_reset_tokens (token_hash);
CREATE INDEX        IF NOT EXISTS password_reset_tokens_user_idx ON password_reset_tokens (user_id, created_at DESC);
CREATE INDEX        IF NOT EXISTS password_reset_tokens_ip_idx   ON password_reset_tokens (ip_hash, created_at) WHERE ip_hash IS NOT NULL;

-- Records a reset request. Returns who to email ({ send: true, name, email }),
-- or { send: false } when there is nothing to send (unknown email, or a rate
-- limit). The API never tells the caller which.
CREATE OR REPLACE FUNCTION grogu_password_reset_request(
  p_email text, p_token_hash text, p_ip_hash text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  u users;
BEGIN
  IF p_ip_hash IS NOT NULL AND (SELECT count(*) FROM password_reset_tokens
        WHERE ip_hash = p_ip_hash AND created_at > now() - interval '1 hour') >= 10 THEN
    RETURN jsonb_build_object('send', false, 'reason', 'ip-limit');
  END IF;

  SELECT * INTO u FROM users
   WHERE lower(email) = lower(btrim(coalesce(p_email, ''))) AND role <> 'Admin';
  IF u.id IS NULL THEN
    RETURN jsonb_build_object('send', false, 'reason', 'unknown');
  END IF;

  IF (SELECT count(*) FROM password_reset_tokens
       WHERE user_id = u.id AND created_at > now() - interval '1 hour') >= 3 THEN
    RETURN jsonb_build_object('send', false, 'reason', 'user-limit');
  END IF;

  -- Only the newest link works.
  UPDATE password_reset_tokens SET used_at = now()
   WHERE user_id = u.id AND used_at IS NULL;

  INSERT INTO password_reset_tokens (user_id, token_hash, ip_hash, expires_at)
  VALUES (u.id, lower(p_token_hash), p_ip_hash, now() + interval '30 minutes');

  RETURN jsonb_build_object('send', true, 'name', u.name, 'email', u.email);
END;
$$;

-- Sets the new password if the token is valid, unused and unexpired.
CREATE OR REPLACE FUNCTION grogu_password_reset_complete(p_token_hash text, p_password text) RETURNS jsonb
  LANGUAGE plpgsql AS $$
DECLARE
  t password_reset_tokens;
  u users;
  v_password text := coalesce(p_password, '');
BEGIN
  SELECT * INTO t FROM password_reset_tokens
   WHERE token_hash = lower(coalesce(p_token_hash, ''))
     FOR UPDATE;

  IF t.id IS NULL OR t.used_at IS NOT NULL OR t.expires_at < now() THEN
    RAISE EXCEPTION 'This reset link is invalid or has expired. Ask for a new one.' USING ERRCODE = 'GR005';
  END IF;
  IF length(v_password) < 8 THEN
    RAISE EXCEPTION 'Password must be at least 8 characters.' USING ERRCODE = 'GR005';
  END IF;
  IF length(v_password) > 128 THEN
    RAISE EXCEPTION 'Password must be at most 128 characters.' USING ERRCODE = 'GR005';
  END IF;

  UPDATE users SET password = crypt(v_password, gen_salt('bf', 10)), password_changed_at = now()
   WHERE id = t.user_id
  RETURNING * INTO u;

  UPDATE password_reset_tokens SET used_at = now()
   WHERE user_id = t.user_id AND used_at IS NULL;

  PERFORM grogu_notify(u.id, 'system', 'Your password was changed',
    'If this wasn''t you, reset your password again and contact support.', NULL);

  RETURN jsonb_build_object('email', u.email, 'userId', u.id);
END;
$$;

-- When the user's password last changed, as epoch seconds (0 if never), for
-- rejecting bearer tokens issued before it.
CREATE OR REPLACE FUNCTION grogu_password_changed_epoch(p_user_id integer) RETURNS bigint
  LANGUAGE sql STABLE AS $$
  SELECT coalesce(floor(extract(epoch FROM password_changed_at))::bigint, 0) FROM users WHERE id = p_user_id;
$$;

COMMIT;
