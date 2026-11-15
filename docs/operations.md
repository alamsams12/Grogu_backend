# Operations runbook

This is the minimum operating contract for the production API.

## Health and availability

- Configure Render's health-check path as `/api/health`.
- Treat a non-200 response from that endpoint as an incident. It confirms the
  process is serving HTTP, but it does **not** exercise Neon; add a protected
  database readiness check before relying on it as a full dependency check.
- Keep Render's deploy logs and health-check history as the first source of
  evidence during a failed release.

## Releases

1. Open a pull request; the required `Backend CI` checks must pass.
2. Apply additive SQL migrations to the target Neon database before releasing
   application code that calls new database functions or columns.
3. In Render, set the Git-connected service's Auto-Deploy mode to **After CI
   Checks Pass**, then merge to the protected production branch. Render will
   deploy only the verified commit. A deploy hook is an alternative for an
   explicitly controlled release process; store its URL as a GitHub secret.
4. Confirm `/api/health`, the Render deployment status, and a representative
   authenticated user journey after deployment.
5. Record the deployed Git commit and migration version in the release notes.

Migrations 008 and 009 (review rewards, reputation) must be applied together,
in order, before the API build that includes `FeedbackV1Controller` and the game
key endpoints. 008 converts each tester's current reputation into one `baseline`
event; 009 then grants the profile bonuses existing testers already qualify for,
without sending notifications. Check afterwards that no tester's
`players.reputation` differs from the sum of their `reputation_events`.

Migration 011 (matching) must be applied before the API build that includes
`MatchingV1Controller`. It uses no new settings: matching shares the Gemini key
and limits with the summaries, and works without a key.

Migrations 013–015 (public game pages, reward pools, password reset) must be
applied before the API build that includes `PublicGamesV1Controller`,
`PaymentsV1Controller` and the forgot/reset password endpoints. 014 changes
review approval: a cash reward now needs enough in the playtest's reward pool,
so existing playtests with a cash reward must be funded before reviews can be
approved with cash (approval without cash is unchanged). 015 makes the API
reject bearer tokens issued before a user's last password change.

Do not run database migrations automatically in the application container.
They can be destructive or long-running, and a deploy may start more than one
instance. Automate migrations later through a single, manually approved job.

## Configuration and secrets

- Store `ConnectionStrings__NeonDBConnection` and `Jwt__Key` only in Render's
  secret environment variables (and GitHub Environments if a deployment action
  needs them).
- Set `Cors__AllowedOrigins__0` to the exact production frontend origin; add
  further numbered variables only for intentional additional origins.
- Rotate the Neon credential mentioned in the repository README: it was
  previously committed to history.
- Gemini (feedback summaries): set `Gemini__ApiKey` as a secret environment
  variable on the API service only. It is optional; without it the API runs
  normally and studios see rule-based summaries. Apply migration 010 before the
  API build that includes `InsightsV1Controller`. The default model
  (`gemini-3.1-flash-lite`) is a setting, `Gemini__Model`. Google retires model
  names, so confirm the model is offered to the key before relying on it. The call limits (`Gemini__CooldownSeconds`,
  `Gemini__MaxCallsPerMinute`) are per API instance, so scaling to several
  instances multiplies the effective rate. Review text (no names, emails or ids)
  is sent to Google, so mention that in any privacy notice.
- Keep `NEXT_PUBLIC_API_BASE_URL` public. It is intentionally sent to browsers;
  never put a database URL, JWT signing key, or service-role key in a
  `NEXT_PUBLIC_*` variable.

- Razorpay (reward pools): `Razorpay__KeyId`, `Razorpay__KeySecret` and
  `Razorpay__WebhookSecret`, all secret except the key id (sent to browsers so
  Checkout can open). Add the webhook in the Razorpay dashboard at
  `<api>/api/v1/payments/webhook` with events `payment.captured`, `order.paid`
  and `payment.failed`. Use `rzp_test_` keys until KYC and a live account are
  ready. Only the amount stored when the order was created is ever credited.
- Email (password reset): `Email__ResendApiKey`, `Email__From` (a domain verified
  in Resend) and `App__FrontendUrl` (links in emails; never taken from the
  request). Without a key the reset form still answers normally but no email is
  sent.
- Anonymous bug reports and reviews are rate-limited per salted IP hash
  (`Abuse__Salt`, defaulting to the JWT key). Optional Cloudflare Turnstile:
  `Turnstile__SecretKey` with `NEXT_PUBLIC_TURNSTILE_SITE_KEY` on the frontend.

## Rollback

1. Roll back the Render service to the last known-good image/commit.
2. Do not roll back an additive database migration blindly. Prefer a forward
   fix or a separately reviewed, reversible migration.
3. Recheck the health endpoint and the user journey; document the incident and
   the commit that introduced it.
