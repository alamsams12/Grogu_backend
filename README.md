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
    `testProgress`, `notifications`, `stats`, `gameKeys`, `ledgerEntries`,
    `wallet`, `reputationEvents`, `reputationRules`, `reputationLevels`), scoped
    to the bearer token. Anonymous callers get the public slice used by the
    marketing pages. `gameKeys` only ever holds the signed-in studio's own keys;
    `wallet` (balance and UPI id) is only returned to the tester it belongs to.
* **Games (`/api/v1/games`)** — `POST`, `PATCH /{id}` (accepts `coverImageUrl`),
  `POST /{id}/keys` (`{ "codes": [...] }`, adds reward keys; duplicates skipped),
  `DELETE /{id}/keys/{keyId}` (unused keys only)
* **Insights (`/api/v1/playtests/{id}/insights`)** — the studio's summary of a
  playtest's feedback: `summary`, `highlights`, `likes`, `dislikes`, `bugs`,
  `actions`, sentiment counts, and where the text came from (`source`: `ai` or
  `rules`). `GET` never calls Gemini: it returns the cached AI summary or a
  summary computed in SQL. `POST` asks Gemini for a new one, but only when
  feedback has arrived since the last, and only the owning studio may call
  either. Gemini being off, rate-limited, slow or wrong is never an error: the
  response falls back to the last cached summary or the SQL one and carries a
  `notice` saying why. Only anonymised review text (no names, emails or ids)
  is sent to Gemini.
* **Matching** — who fits which playtest. Eligibility and scores come from rules
  in SQL; Gemini, when it is on, may only re-order the top of the list and add a
  reason per entry (see **AI feedback summaries and matching**).
  * `GET`/`POST /api/v1/playtests/{id}/suggestions` — testers who fit a recruiting
    playtest, for the studio that owns it. Up to 10, with `score` (0–100),
    `reasons`, `aiReason` and `invited`.
  * `POST /api/v1/playtests/{id}/invites` — `{ "testerId": "12" }`. The tester gets
    one in-app notification; inviting again is harmless. Recruiting playtests only,
    not testers who already applied, at most 50 per playtest.
  * `GET`/`POST /api/v1/recommendations` — open playtests that fit the signed-in
    tester. Up to 6, same fields.
* **Feedback (`/api/v1/feedback`)** — `POST /{id}/review`, the owning studio's
  decision: `{ "decision": "approved" | "rejected", "note"?, "reputationBonus"?,
  "cashAmount"?, "gameKey"? }`. Once only. Approval pays everything in one
  transaction: +15 reputation (plus a bonus up to 50), a ledger entry for cash,
  and one key from the game's inventory. With no key left, nothing is written.
* **Playtests (`/api/v1/playtests`)** — `POST`, `PATCH /{id}`,
  `PATCH /{id}/access` (build link, key and install notes; works after publishing),
  `POST /{id}/status`, `POST /{id}/applications`
* **Uploads (`/api/v1/uploads?kind=poster|review-media|avatar`)** — `POST` multipart, field
  `file`. Returns `{ url, kind, name, size }`. The type is read from the file's bytes
  (PNG, JPEG, WebP, MP4, WebM; SVG is refused). Posters: developers, images up to
  5 MB. Review media: testers, images up to 10 MB or video up to 50 MB. Avatars:
  anyone signed in, images up to 2 MB. Files are
  served from `/uploads/<guid>.<ext>`.
* **Applications (`/api/v1/applications`)** — `POST /{id}/withdraw`, `POST /{id}/decision`
* **Tests (`/api/v1/tests`)** — `POST /{playtestId}/download`,
  `POST /{playtestId}/tasks/{taskId}/toggle`, `POST /{playtestId}/feedback`
* **Notifications (`/api/v1/notifications`)** — `POST /{id}/read`, `POST /read-all`
* **Profile (`/api/v1/profile`)** — `PATCH`. Partial: only the keys present in
  the body are written, so a screen can save one section without clearing the rest.
  Testers can set `upiId` (format-checked only). `avatarUrl` must be an upload or
  an https link. Saving checks the one-time profile reputation bonuses.

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
| `Storage__Path` | no | Folder uploaded files are written to and served from. Defaults to `uploads` next to the app. **Use a persistent disk in production**: on an ephemeral filesystem uploads vanish on redeploy. |
| `Cors__AllowedOrigins__0`, `__1`, ... | yes for deployed frontends | Browser origins allowed to call the API. `http://localhost:3000` and `:3001` are always allowed. |
| `Gemini__ApiKey` | no | Google Gemini API key for feedback summaries. **Server-side only**; never put it in a frontend variable. Without it the API runs normally and summaries use the rule-based fallback. |
| `Gemini__Model` | no | Model id. Defaults to `gemini-3.1-flash-lite`. Google retires model names over time (`gemini-2.5-flash` now returns 404 for new keys), so if summaries stop working with "didn't respond", list the models your key offers and set this. |
| `Gemini__BaseUrl` | no | Defaults to `https://generativelanguage.googleapis.com`. Only changed to point at a test stub. |
| `Gemini__TimeoutSeconds`, `Gemini__CooldownSeconds`, `Gemini__MaxCallsPerMinute` | no | Free-tier guards: how long to wait for Gemini (30), how long before the same playtest may be summarised again after an attempt (60), and calls per minute for the whole process (10). |

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
| `007_assets_and_playtest_access.sql` | Poster support in `grogu_game_save`; playtest install instructions and access key; up to six review attachments. **Closes a leak:** `build_url` used to be returned to every viewer of `GET /api/v1/bootstrap`. The base playtest JSON now blanks the access fields, and `grogu_playtest_view` returns them only to the owning studio and accepted testers. Adds URL validators and `grogu_playtest_access_save`. |
| `008_review_approval_and_rewards.sql` | Phase 4. Review status on feedback (`submitted` → `approved` or `rejected`) and `grogu_feedback_review`. `game_keys` inventory, allocated under `FOR UPDATE SKIP LOCKED` with a unique index on `feedback_id`, so two approvals never share a key. `ledger_entries` money ledger (balance = sum, append-only). `reputation_rules` and `reputation_events`: `players.reputation` becomes a cache of the event sum, with existing reputation carried over as one `baseline` event. New testers now start at 0. |
| `009_reputation_levels_and_wallet.sql` | Phase 5. `reputation_levels` thresholds; earning rules for profile completion, being accepted, completing a test and detailed reviews; level-up and bonus notifications; `players.upi_id`; avatar URL validation. Existing testers get the profile bonuses they qualify for, without notifications. |
| `010_playtest_insights.sql` | Phase 6A. `playtest_insights` (one cached AI summary per playtest, with the feedback it covers so staleness is exact), the rule-based summary in SQL (`grogu_insight_rules`), the anonymised model input (`grogu_insight_inputs`), and `grogu_insight_view` / `_prepare` / `_store`. `grogu_insight_clean` is the single place that decides what a stored summary may contain. |
| `011_matching.sql` | Phase 6B and 6C. `grogu_match_candidates`: the eligibility filters (platform, language, minimum experience and reputation, not applied, playtest recruiting, open and not full) and the weighted score, with reasons. `matching_weights` holds the weights per side, so ranking can be tuned without a migration. `playtest_invites`, `match_ai_cache` (AI ranking stored against a fingerprint of the shortlist), the studio and tester views, and `grogu_playtest_invite`. Adds the `playtest-invite` notification type. |

They are additive and safe to re-run. 001 and 002 must be applied together:
001 replaces the plaintext passwords with bcrypt digests, and 002 is what
teaches the legacy login function to verify them.

**Development seeds.** `db/seeds/` holds dev-only data. It is idempotent, and it
must **not** be run against a database with real users. Seeds run in filename
order:

| File | What it adds |
| --- | --- |
| `001_dev_testers_and_studios.sql` | 25 playtesters and 3 game studios, all with the shared password `playtest` and `@example.com` addresses. Accounts are created through `grogu_signup`, so they match what the signup form produces. |
| `002_dev_games_and_playtests.sql` | 11 games and 14 playtests in every lifecycle state (draft through archived), with applications, test progress, feedback, notifications, and placeholder build links, install notes and NDA access keys. It drives the real `grogu_*` functions, so the data is valid by construction. Re-running fills in access details that are still blank. Needs 001 first. |
| `003_dev_rewards.sql` | Eight placeholder reward keys per seeded game, and studio decisions through `grogu_feedback_review`: most "The Long Harbour: accessibility pass" reviews approved with cash and keys (one rejected), and the demo tester's Saltmarsh review approved. The demo studio's "Tidepool Keeper" reviews are left for you to decide. Needs 002 first. |

**Database scripts.** `db/apply.sh` runs the migrations, seeds or SQL tests
against the local compose database (see Local database below), or against any
database named by `DATABASE_URL`. Seeds refuse a `DATABASE_URL` target unless
`ALLOW_REMOTE_SEED=1` is set:

```bash
db/apply.sh migrations
db/apply.sh seed
db/apply.sh tests      # db/tests/*.sql; each file rolls back, leaving no data
```

**Security note.** Before this work, passwords were stored and compared in
plaintext (`register_user` inserted the raw string, `verify_user_login`
compared it with `=`). 001 hashes every existing credential in place. The
connection string was also committed to `appsettings.json`; it has been removed,
but it remains in this repository's git history, so **the database password
should be rotated**.

---

**Local database and API (development)**

`docker-compose.yml` lives in the Grogu folder, one level above this repository.
It starts a PostgreSQL 16 database on host port **5433** and this API. Its
credentials are local placeholders; never use them anywhere shared.

Use port **8081** for the API. Another container on this machine may already
hold 8080, and the frontend's `.env.local` expects 8081.

```bash
# From the Grogu folder (Git Bash or any bash)
cd "/d/Vibe Code Startups/Grogu"
API_PORT=8081 docker compose up -d --build
```

PowerShell equivalent:

```powershell
cd "D:\Vibe Code Startups\Grogu"
$env:API_PORT = "8081"
docker compose up -d --build
```

Check that it answers:

```bash
curl -s http://localhost:8081/api/v1/bootstrap | head -c 200
```

**First run only, on an empty database:** create the tables and the demo data
(run from `Project-Grogu-Backend`, or with the full path to `db/apply.sh`):

```bash
db/apply.sh migrations     # apply db/migrations/*.sql in order
db/apply.sh seed           # dev accounts and content; safe to re-run
db/apply.sh tests          # optional; each test file rolls back
```

Do not run `migrations` against a database that already has data you care
about. `docker compose down` keeps the database; `docker compose down -v`
deletes it, so you would need to migrate and seed again.

Demo logins (password `playtest`): `priya.nair@example.com` (tester),
`mara@driftwoodgames.dev` (developer), and any seeded `@example.com` address.

Every change to the API needs a rebuild of the container:
`API_PORT=8081 docker compose up -d --build api`.

**Running the API without Docker** (needs the .NET 5 SDK and a PostgreSQL you
can reach):

```bash
export ConnectionStrings__NeonDBConnection="Server=localhost;Port=5433;Database=grogu;User Id=grogu;Password=grogu_dev"
export Jwt__Key="$(openssl rand -base64 48)"
dotnet run --project Grogu_backend
```

Swagger is served at `/swagger` in every environment.

---

**AI feedback summaries and matching (Gemini)**

The same key and limits serve two features: the feedback summary below, and the
matching lists (suggested testers for studios, recommended playtests for
testers). Matching works the same way as the summary: `GET` never calls Gemini,
`POST` asks for a fresh AI ranking only when the rule-based list has changed, and
any failure falls back to the rule order with a `notice`.

*How matching decides.* A tester is eligible for a playtest only if the playtest
is recruiting, open and not full, the tester has not applied, has one of the
required platforms and languages, and meets the minimum experience and
reputation. Eligible pairs get a 0–100 score, a weighted average of factors in
`matching_weights`:

| Studio side (testers for a playtest) | Tester side (playtests for a tester) |
| --- | --- |
| genre 30, reputation level 20, reliability (finished vs accepted tests) 20, approved reviews 10, weekly hours 10, experience above the minimum 10 | genre 35, invited by the studio 20, reputation bar close to theirs 15, weekly hours 15, spots left 10, cash reward 5 |

Change a weight with an `UPDATE matching_weights ...`; a weight of 0 turns a
factor off. Gemini receives the top of the list with ids replaced by `c1`, `c2`,
... and no names, emails or bios. Its answer may only re-order that list: unknown
keys are dropped, and testers or playtests it leaves out keep their rule order.

**The feedback summary**

A studio's Analytics tab shows a summary of its feedback: the overall mood,
highlights, what testers like and dislike, bugs and suggested next steps.
Google Gemini writes it when a key is set. Without a key, or whenever Gemini is
unavailable, the server computes the same shape from the reviews itself, and the
panel says it is an automatic summary.

*How it behaves*

- `GET /api/v1/playtests/{id}/insights` never calls Gemini. It returns the
  cached summary, or an automatic one if there is none.
- `POST` on the same path asks Gemini for a new summary, but only when feedback
  has arrived since the last one. The frontend calls it once per visit when a
  summary is stale, and the studio can press **Update summary**.
- A failed call never breaks the page. The response falls back and carries a
  `notice` saying why.
- Sentiment counts always come from the reviews, never from the model.
- Only the owning studio can read or write a playtest's insights.

*What is sent to Google.* For each review: the five ratings, the sentiment label,
the summary, highlights, pain points, bugs, would-recommend and hours played,
with text cut to length. The newest 60 reviews are used. Tester names, emails
and ids are not sent. Review text is treated as data by the instruction, and
the answer is checked against a fixed JSON schema before it is stored.

*Set it up locally*

1. Create a key at <https://aistudio.google.com/apikey>.
2. Create a file named `.env` in the Grogu folder, next to `docker-compose.yml`:

   ```
   GEMINI_API_KEY=paste-your-key-here
   GEMINI_MODEL=gemini-3.1-flash-lite
   ```

   `GEMINI_MODEL` is optional; `gemini-3.1-flash-lite` is the default. Docker
   Compose reads `.env` automatically. Keep this file out of any git repository.
3. Restart the API: `API_PORT=8081 docker compose up -d api`.
4. Open a playtest with feedback as the studio, then Analytics. The first
   insights request writes `Gemini is enabled (model ...)` to the API log.
   `docker logs grogu-api-1 2>&1 | grep -i gemini` shows it.

Without a key the API runs normally. `Gemini__ApiKey` is the matching setting
for deployed services; never put the key in a frontend variable.

*Settings*

| Setting | Default | Meaning |
| --- | --- | --- |
| `Gemini__ApiKey` / `GEMINI_API_KEY` | empty (AI off) | The key. |
| `Gemini__Model` / `GEMINI_MODEL` | `gemini-3.1-flash-lite` | The model. |
| `Gemini__TimeoutSeconds` / `GEMINI_TIMEOUT_SECONDS` | 30 | How long to wait for Gemini. |
| `Gemini__CooldownSeconds` / `GEMINI_COOLDOWN_SECONDS` | 60 | Wait after an attempt before the same playtest is tried again. |
| `Gemini__MaxCallsPerMinute` / `GEMINI_MAX_CALLS_PER_MINUTE` | 10 | Calls per minute for the whole API process. |
| `Gemini__BaseUrl` / `GEMINI_BASE_URL` | Google's API | Only changed to point at a test stub. |

The two slash forms are the same setting: `Gemini__X` is the .NET configuration
name, and `GEMINI_X` is what `docker-compose.yml` reads from `.env`.

*When it says something went wrong*

| Notice shown to the studio | Usual cause | What to do |
| --- | --- | --- |
| AI summaries aren't switched on for this server | No key set | Set `GEMINI_API_KEY` as above. |
| AI summaries are limited to stay within the free quota | Per-minute cap, or Google answered 429 | Wait a minute. |
| The last AI attempt for this playtest didn't finish | The 60-second cooldown after an attempt | Wait a minute, then press Update summary. |
| The AI service is busy | Two summaries already running | Try again shortly. |
| The AI service didn't respond | Timeout, a Google 5xx, or a rejected key or model | Check the API log (below). |
| The AI service returned something unusable | Bad JSON, an empty summary, or a cut-off answer | Try again later. |
| The AI service declined to summarise this feedback | Google's safety filter | The automatic summary is shown instead. |

The matching lists show the same notices, with "AI rankings" in place of "AI
summaries" and "declined to rank this list" for a safety block.

The API log gives the HTTP status. `Gemini rejected the request (HTTP 404)`
means the key or the model name is wrong. Google retires model names, and
`gemini-2.5-flash` now returns 404 for new keys, so set `GEMINI_MODEL` to a
model your key offers. The list of models your key can use:

```bash
KEY=$(grep ^GEMINI_API_KEY= "/d/Vibe Code Startups/Grogu/.env" | cut -d= -f2- | tr -d '\r')
curl -s -H "x-goog-api-key: $KEY" "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200" \
  | python -c "import sys,json; [print(m['name'][7:]) for m in json.load(sys.stdin)['models'] if 'generateContent' in m.get('supportedGenerationMethods',[])]"
```

`HTTP 503 ... high demand` is Google being busy for a while; the automatic
summary covers it, and the studio can try again later.

*Testing without a real key:* point `GEMINI_BASE_URL` at any server that answers
`POST /v1beta/models/{model}:generateContent` with a Gemini-shaped JSON response.

---

