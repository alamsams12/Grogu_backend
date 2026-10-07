# Project Grogu Backend

This repository contains the backend Web API for **Project Grogu**, built using **.NET 5**, **C#**, and **NeonDB (PostgreSQL)**. The architecture utilizes direct database communication via `Npgsql` and offloads core business logic to PostgreSQL stored functions.

---

**Tech Stack**
* **Framework:** .NET 5 Web API (C#)
* **Database:** NeonDB (Serverless PostgreSQL)
* **Data Access:** Npgsql (Direct SQL execution with stored procedures/functions)
* **Frontend Integration:** Linked with the Vercel-hosted client (`https://project-grogu-pi.vercel.app/`)

---

**Project Structure & Endpoints**

* **Auth (`/api/auth`)**
  * `POST /api/auth/signup`: Registers a new user (`Player`, `Studio`, or `Admin`).
  * `POST /api/auth/login`: Authenticates credentials against stored functions and returns user session details.
* **Players (`/api/players`)**
  * `POST /api/players/saveProfile`: Onboards or updates player profile details (age, experience, platforms, genres) linked by `userId`.
  * `PUT /api/players/{id}`: Partially updates player profile properties using SQL `COALESCE`.
  * `DELETE /api/players/{id}`: Deletes a player record.
  * `POST /api/players/apply`: Allows players to apply for playtests.
* **Studios (`/api/studios`)**
  * `GET /api/studios/{id}`: Retrieves studio details.
  * `PUT /api/studios/{id}`: Updates studio profile information.
  * `GET /api/studios/{id}/playtests`: Lists all playtests created by the studio.
  * `DELETE /api/studios/{id}`: Deletes a studio profile.
* **Playtests (`/api/playtests`)**
  * `POST /api/playtests`: Creates a new playtest session.
  * `GET /api/playtests/{id}`: Fetches playtest details.
  * `GET /api/playtests/{id}/applications`: Retrieves all player applications for a specific playtest.
* **Applications (`/api/applications`)**
  * `GET /api/applications/{id}`: Fetches application details.
  * `PUT /api/applications/{id}/status`: Updates application status (e.g., Pending, Approved, Rejected).
  * `DELETE /api/applications/{id}`: Removes an application.
* **Feedback (`/api/feedback`)**
  * `POST /api/feedback`: Submits player feedback and ratings for completed playtests.
  * `GET /api/feedback/{id}`: Fetches specific feedback.
  * `GET /api/feedback/playtest/{playtestId}`: Retrieves all feedback submitted for a playtest.
  * `DELETE /api/feedback/{id}`: Deletes a feedback entry.
* **Users (`/api/users`)**
  * `GET /api/users/{id}`: Fetches user info.
  * `PUT /api/users/{id}`: Updates user details.
  * `DELETE /api/users/{id}`: Deletes a user record.


**The `/api/v1` surface (what the frontend uses)**

`/api/v1/*` is built to the contract the frontend declares in
`Project-Grogu-Frontend/lib/types.ts`. It speaks JSON (not form fields),
camelCase, string ids, and bearer-token auth. The older `/api/*` endpoints
listed above are unchanged and still work.

* **Auth (`/api/v1/auth`)**
  * `POST /signup` — `{role, name, email, password, location, ...}` → `{token, expiresAt, user, role}`
  * `POST /login` — `{email, password}` → the same
  * `GET /session` — the caller's own user, for validating a stored token
  * `POST /logout`
* **Bootstrap (`/api/v1/bootstrap`)**
  * `GET` — every collection the client caches (`users`, `testerProfiles`,
    `developerProfiles`, `games`, `playtests`, `applications`, `feedback`,
    `testProgress`, `notifications`, `stats`), scoped to the bearer token.
    Anonymous callers get the public slice used by the marketing pages.
* **Games (`/api/v1/games`)** — `POST`, `PATCH /{id}`
* **Playtests (`/api/v1/playtests`)** — `POST`, `PATCH /{id}`,
  `POST /{id}/status`, `POST /{id}/applications`
* **Applications (`/api/v1/applications`)** — `POST /{id}/withdraw`, `POST /{id}/decision`
* **Tests (`/api/v1/tests`)** — `POST /{playtestId}/download`,
  `POST /{playtestId}/tasks/{taskId}/toggle`, `POST /{playtestId}/feedback`
* **Notifications (`/api/v1/notifications`)** — `POST /{id}/read`, `POST /read-all`
* **Profile (`/api/v1/profile`)** — `PATCH`. Partial: only the keys present in
  the body are written, so a screen can save one section without clearing the rest.

Errors are `{ "message": "...", "code": "..." }`, where `code` is one of
`not-found`, `invalid-credentials`, `conflict`, `forbidden`, `validation` or
`server-error`, matching the frontend's `ServiceError`.

**Where the logic lives**

Business logic stays in PostgreSQL stored functions, as it always has. The v1
controllers are thin: they take the caller's id from the validated JWT, pass the
request body through as `jsonb`, and return the function's jsonb result
verbatim. The functions are named `grogu_*` and raise custom SQLSTATEs
(`GR001`–`GR005`) that `Infrastructure/GroguDb.cs` maps onto HTTP status codes.

Because the contract is defined once, in SQL, there are no C# DTOs restating
the frontend's types.

---

**Configuration**

Nothing secret is committed. The app reads these from the environment and
refuses to start without the ones marked required:

| Variable | Required | Purpose |
| --- | --- | --- |
| `ConnectionStrings__NeonDBConnection` | yes | Npgsql connection string for the Neon database. |
| `Jwt__Key` | yes in Production | HMAC-SHA256 signing key, **at least 32 characters**. Generate with `openssl rand -base64 48`. In Development a random key is generated per run. |
| `Jwt__Issuer` | no | Defaults to `grogu-backend`. |
| `Jwt__Audience` | no | Defaults to `grogu-frontend`. |
| `Cors__AllowedOrigins__0`, `__1`, ... | yes for deployed frontends | Browser origins allowed to call the API. `http://localhost:3000` and `:3001` are always allowed. |

Example (local):

```bash
export ConnectionStrings__NeonDBConnection="Server=...;Database=neondb;User Id=...;Password=...;SSL Mode=Require;Trust Server Certificate=true"
export Jwt__Key="$(openssl rand -base64 48)"
export Cors__AllowedOrigins__0="https://your-frontend.vercel.app"
dotnet run --project Grogu_backend
```

---

**Database migrations**

`db/migrations/` holds ordered, idempotent SQL. Apply them in filename order
against the target database **before** deploying the matching code:

```bash
for f in db/migrations/*.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || break
done
```

| File | What it does |
| --- | --- |
| `001_frontend_contract_schema.sql` | Adds the columns and tables the frontend's domain model needs (`games`, `playtest_tasks`, `test_progress`, `notifications`, and new columns on the existing tables), hashes all stored passwords with bcrypt, backfills legacy rows, and re-syncs identity sequences. |
| `002_frontend_contract_functions.sql` | Vocabulary mapping, entity→JSON builders, and bcrypt-aware replacements for the legacy `register_user` / `verify_user_login`. |
| `003_frontend_contract_operations.sql` | The read and write operations behind `/api/v1`. |
| `004_demo_accounts.sql` | The two demo logins the frontend's login screen offers, plus a game and an open playtest so a fresh database is not empty. |
| `005_profile_save_partial_update.sql` | Makes `grogu_profile_save` honour PATCH semantics — the original wiped a tester's platforms and genres when the request omitted them. |
| `006_playtest_requirements_defaults.sql` | Guarantees a playtest's `requirements` always carries all seven `TesterRequirements` fields, and backfills rows written before the fix. |

They are additive and safe to re-run. 001 and 002 must be applied together:
001 replaces the plaintext passwords with bcrypt digests, and 002 is what
teaches the legacy login function to verify them.

**Security note.** Before this work, passwords were stored and compared in
plaintext (`register_user` inserted the raw string, `verify_user_login`
compared it with `=`). 001 hashes every existing credential in place. The
connection string was also committed to `appsettings.json`; it has been removed,
but it remains in this repository's git history, so **the database password
should be rotated**.

---

**Local development**

The Dockerfile matches the deployed image, so the quickest check that a change
compiles and runs is:

```bash
docker build -t grogu-backend .
docker run --rm -p 8080:80 \
  -e ConnectionStrings__NeonDBConnection="..." \
  -e Jwt__Key="$(openssl rand -base64 48)" \
  grogu-backend
curl localhost:8080/api/health
```

Swagger is served at `/swagger` in every environment.

---

