# soma

Soma is TinyBrains' public API, its schema and the life cycle of a model version: sign-in,
submissions, admission, trials, promotion, pairing, rating and seasons. It is an Orion 1.9.0 package
(REST channels, cron clocks, workflows, connectors and two Rust/wasm plugins) plus the Postgres
migrations every package shares, shipped as the node image `ghcr.io/tiny-brains/soma`.
[Kalam](https://github.com/Tiny-Brains/kalam) runners play the matches Soma queues, and
[web](https://github.com/Tiny-Brains/web) is the site in front of it and the local stack.

**Owns:** GitHub sign-in and sessions · public reads · submissions and their presigned uploads ·
seasons, their boards and baselines · admission, pairing, trials, promotion, rating, withdrawal and
the season close · the runner gate `/v1/runner/*` · notifications · the schema and the `kalam` /
`runner_gate` grants. **Does not:** run any model -- a submission is admitted on an admitting
runner and matches are played on runners (Kalam) · write replays · implement game rules (the Ants
cartridge) · decide deployment addresses, credentials or replica counts.

```text
browser ──▶ web nginx ──/v1/──▶ ┌── Soma node × N (Orion, cluster mode) ────────────────┐
Kalam runner ──/v1/runner/*───▶ │ routes · runner gate · clocks · tb.rating · tb.pairing │── SQL ──▶ Postgres
                                │ tb.ants (map checks) · no models entity                │
                                └──┬─────────────────────┬───────────────────────────────┘
                     presign PUT/GET│                     │ HEAD + GET the manifest
competitor ──presigned PUT──▶ models bucket (public-read) ◀── runners fetch by digest (the admitting one first)
runner ──presigned PUT──────▶ replay bucket (private)     ◀── browsers, presigned GET
```

Soma and Kalam never call each other: they meet in the schema. A runner holds no database
credential and reaches the queue only through the gate's routes, which run the match statements as
the `runner_gate` role.

## Quick start

The local stack is web's `docker-compose.yml` (Postgres, Redis, MinIO, Soma, the Orion console, the
site); its README covers the first run (`scripts/setup/init.sh`, the OAuth App). To run this
checkout in it:

```sh
docker build -t tinybrains/soma:dev .                         # add --build-context ants=../ants/dist for an unreleased engine
cd ../web && SOMA_IMAGE=tinybrains/soma:dev docker compose up -d
docker compose logs -f soma                                   # wait for "==> loaded: tb.rating, tb.pairing and tb.ants are live"
curl -fsS http://127.0.0.1:8080/v1/games
```

The image has two commands. `bootstrap` runs once before any node: it creates `orion_state`,
applies the migrations to an empty database (and refuses a database whose recorded schema digest
differs), registers the game, sets the `runner_gate` password, declares the engine digest and
registers the cartridge's manifest and reference observations. It seeds nothing an admin makes: a
fresh platform has no season until an admin creates one. `serve` (the default) migrates
Orion's state, loads the package into the node, and stops the node if a plugin failed to load or a
channel is quarantined.

## Interface

**Auth modes.** *Public*: no credential. *Session*: an HS256 JWT in the HttpOnly `soma_session`
cookie (issuer `soma`, 30 days), checked against `live_sessions` inside every query, so revocation
is immediate. *Admin*: a session whose live `users.role` is `admin`, read off the row, never off the
cookie. *Runner*: an `Authorization: Bearer` JWT with `aud: runner`, signed with
`RUNNER_TOKEN_SECRET`, ten minutes, checked against `live_runners` inside every statement. Every
channel but `/v1/admin-check` also has an address-keyed `rate_limit` applied before auth, and authed
channels add a per-principal quota.

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/v1/auth/github` | Public | Redirect to GitHub (state, PKCE, `?next=`); the same channel serves `/callback` and sets the cookie |
| GET · PATCH | `/v1/me` | Session | Current user and any version in flight · `display_name` |
| GET | `/v1/me/matches` | Session | The caller's matches in every state, queued and cancelled included |
| GET | `/v1/me/notifications` | Session | Feed: `category`, `unread`, `since`, `cursor`, `limit`; unread count |
| POST | `/v1/me/notifications/read` | Session | `ids`, or `all` with an optional `category` |
| GET · PATCH | `/v1/me/notification-settings` | Session | Per category `app`, `push`, `level`; 409 `category_locked` |
| GET | `/v1/sessions` | Session | Live sessions |
| DELETE | `/v1/sessions/{sid}` · `/v1/session` | Session | Revoke one (`others` = all but this one) · sign out |
| GET | `/v1/admin-check` | Session | **204** admin, **401** no or revoked session, **403** signed-in non-admin; no body |
| GET | `/v1/status` | Public | Queue, throughput and how far each clock is behind |
| GET | `/v1/games` · `/v1/games/{game}` | Public | Games with their current season · one game: `about`, effective limits (`limits.boards`), weight classes |
| GET | `/v1/games/{game}/leaderboard` | Public | `ladder`, `season`, `limit`, `cursor` |
| GET · POST | `/v1/games/{game}/seasons` | Public · Admin | Seasons with counts · create `{name, submissions_open_at, submissions_close_at, rules?, weight_classes?}` |
| PATCH | `/v1/games/{game}/seasons/{slug}` | Admin | Edit a season that has not opened; name and slug are refused |
| POST | `/v1/games/{game}/seasons/{slug}/close` | Admin | Request a close; 202, consumed by the withdraw clock |
| GET | `.../seasons/{slug}/maps` · `.../maps/{map_id}` | Public | A season's boards, enabled or not (`?enabled=`, `?boards=`) · one board and its history |
| POST · PATCH | `.../seasons/{slug}/maps` · `.../maps/{map_id}` | Admin | Upload one map file, stored disabled · `{"enabled": bool}` |
| GET · POST | `.../seasons/{slug}/baselines` | Admin | Baselines and refused uploads · `{name, weights_hash, manifest_hash}`, answered with two presigned PUTs |
| PATCH | `.../seasons/{slug}/baselines/{baseline}` | Admin | `{"enabled": bool}`; `{baseline}` is the slug of its name |
| POST | `/v1/games/{game}/models` | Session | Create an entry `{name}` |
| GET | `/v1/models` | Session | The caller's versions with ratings and ranks; `?game=` |
| GET · PATCH | `/v1/models/{id}` | Public · Session | An entry and its versions · `{name, retired}` |
| GET | `/v1/versions/{id}` | Public | One version: status, ladders with rank and field, trial |
| GET | `/v1/games/{game}/submission` | Session | Whether the caller may submit, and why not; `?model=` |
| POST | `/v1/submissions` | Session | `{game, model, weights_hash, manifest_hash}`: a `testing` version and two presigned PUTs; the same hashes again re-sign them |
| GET | `/v1/matches` · `/v1/matches/{id}` | Public | `season`, `model`, `version`, `owner`, `map`, `class`, `ladder`, `outcome`, `players_min/max`, `cursor` · seats, ladders, signed replay URL |
| GET | `/v1/profiles/{username}` | Public | A competitor's public versions by game and season |
| POST · GET | `/v1/runner-keys` | Admin | Mint a key (the only response that carries it) · the caller's keys |
| DELETE | `/v1/runner-keys/{id}` | Admin | Revoke a key and every runner started from it |
| GET · DELETE | `/v1/runners` · `/v1/runners/{id}` | Admin | The fleet · stop one machine, key untouched |
| GET | `/v1/admin/users` | Admin | Every admin, and up to 50 competitors matching `?q=` (handle or display name) |
| PATCH | `/v1/admin/users/{id}` | Admin | `{"role": "admin" \| "competitor"}`; 409 `not_yourself`, `not_a_person` |
| POST | `/v1/runner/token` | Public, address-limited | Key → ten-minute token; the runner self-registers on `(key, label)`; 409 when its `ops_budget` disagrees with a live season |
| POST | `/v1/runner/claim` | Runner | One match and its execution contract, or `200 {"idle": true}` |
| POST | `/v1/runner/matches/{id}/start` · `/renew` · `/release` | Runner | claimed → running · extend the lease (`{applied, lease_expires_at}`) · requeue, spending a refusal |
| POST | `/v1/runner/matches/{id}/replay-url` | Runner | Presigned PUT for `replays/<match>/<claim_token>.json` |
| POST | `/v1/runner/matches/{id}/finish` | Runner | `200 {applied: true}` · `200 {applied: false}` duplicate · `409` claim lost |
| GET | `/v1/runner/roster` | Runner | Every `verified` or `active` version a runner must be able to play |
| POST | `/v1/runner/admissions/claim` | Runner | `{orion_version}` → one prepared submission (registration, key, digest, budget, reference observations) and its claim, or `200 {"idle": true}`; 409 `orion_version_differs` |
| POST | `/v1/runner/admissions/{id}/report` | Runner | `{claim_token, admission, stats, probe}` → `200 {applied: true}` · `200 {applied: false}` duplicate · `409` claim lost |

`/v1/admin-check` exists for nginx `auth_request` (web puts the Orion console behind it): 2xx allows,
401 sends the caller to sign in, 403 refuses. Keep the 401/403 split. The port also serves Orion's
admin API, `/health`, `/readyz` and `/metrics`. Only `/v1/` may be proxied.

## Clocks

Authored as `channels/soma-clock-*.json` and `workflows/soma-clock-*-run.json`, with their
statements in `sql/soma-clock-*.sql`. Each is a `forbid` singleton on its own key with the `latest` misfire policy;
the singleton buys order, and the SQL fences buy correctness.

| Channel | Every | Timeout | Does | Fence |
|---|---|---|---|---|
| `soma-clock-admit` | 20 s | 600 s | Expire, claim `testing` versions, prepare each for an admitting runner or judge its report, write one verdict each | per-row `admit_token` claim |
| `soma-clock-pair` | 15 s | 60 s | Read demand, fill the room with the plugin's plan, insert trials first; halts quietly while no board is in play | roster epoch, checked `FOR SHARE` per insert |
| `soma-clock-count` | 10 s | 60 s | Fold finished matches in finish order, decide trials, promote | run fence on `clocks.count` |
| `soma-clock-withdraw` | 60 s | 30 s | Cancel queue rows that can no longer be played; close the season | none: idempotent |
| `soma-clock-reap-run` | 5 s | 10 s | Return lapsed leases to `pending`; the third lapse fails the row | none: idempotent |

**Version life cycle:** `testing` → admit → `verified` → trial (count) → `active` → `superseded`,
or `rejected` at either step.

**Admission runs no model here.** `soma-clock-admit` walks a submission twice. *Prepare* checks what needs no
model (the object is in the bucket, the manifest hashes to its declaration, the registration rebuilt
from it field by field) and queues one `admissions` row. An **admitting runner** (kalam,
`RUNNER_ROLE=admit`) claims it through the gate, registers it on its own node, lets Orion admit it,
plays it over the first `admit_observations` of the game's reference observations, deletes it and
reports. *Decide* reads the report through `admission_facts()`, measures S' from the clock's own HEAD
and the runner's bytes, picks the class and writes the verdict. A report that decided nothing (the
runner could not fetch, ran out of time, or measured the probe over `max_probe_ms`) goes back to the
queue with its attempt spent; a submission waiting for a runner spends none. Nothing is admitted
while no admitting runner is up. A baseline goes `testing` → `disabled` ⇄ `active`. **Plugins:**
`tb.rating.trueskill` is the TrueSkill update per ladder, pure; `tb.pairing.pair` picks opponents and
boards, pure and seeded by the occurrence id. `tb.ants` is the engine, loaded so a map upload can be
judged by `worldgen`.

| Table | Written by |
|---|---|
| `users`, `sessions` | sign-in, `PATCH /v1/me`, session routes; roles by hand |
| `games` | `bootstrap` |
| `seasons`, `season_maps`, `season_map_events`, `baseline_events` | admin routes; withdraw closes a season; `bootstrap` moves a live season's engine on a patch |
| `models`, `model_versions` | entry and submission routes insert; admit and count decide; baseline flips |
| `matches`, `match_seats` | pair inserts; Kalam claims, plays and finishes (through the gate, or directly in db mode); count rates; withdraw, promotion and disables cancel |
| `ratings`, `rating_events` | count; a baseline's first enable seeds its two ratings at the prior |
| `clocks` | count's fence; every roster change bumps `roster` |
| `runner_keys`, `runners` | admin routes; the token exchange upserts runners |
| `notifications`, `notification_settings` | the writer after each decision; the settings route |

## Development

| Command | What it does | Needs |
|---|---|---|
| `./scripts/check-defs.sh` | `orion-server lint`, `clippy`, `fmt --check`, `check-names.sh`, and `clippy -c docker/soma.toml.tmpl` for the three rules that need the serving config (all `--deny-warnings`) | `orion-server` in `shared/package.json`'s range |
| `./scripts/check-names.sh` | The ids, the three tags and the `sql/` filenames. Derives each channel's surface from its protocol, route and role guard, and fails if the tag or the id's second segment disagrees | nothing; it reads the set |
| `cargo test --manifest-path plugins/Cargo.toml` | Rating and pairing host tests | stable Rust |
| `plugins/build.sh tb-rating` (or `tb-pairing`) | Tests, then the wasm component and `plugin.json` beside the source (gitignored) | `wasm32-unknown-unknown`, `wasm-tools`, Python 3.11+ |
| `./scripts/check-sql.sh` | `orion-server sql check`: prepare every shipped statement against a scratch schema built from `migrations/`, each as its connector's role, and plan it to prove that role's grants | docker, or `SQLCHECK_DATABASE` |
| `./scripts/verify/run.sh` | What the statements mean: the scenario walk, both fence races, that the migrations seed nothing an admin makes, the `kalam` grants. It reads each shipped statement out of the workflow that ships it, so there is no copy to drift | a postgres container (`DB_CONTAINER`) |
| `./scripts/smoke.sh` | Every route's status code with a minted session, against the newest season (create one first); an admin handle adds a runner-key → token → claim round trip | the running stack, package loaded |
| `./scripts/load-package.sh [--prune]` | Compile a working copy and `package apply` it into a running node; `--prune` retires what the applied version carried and this one does not. A node applies its own package at boot without this | `orion-server`, the admin API |
| `docker build -t tinybrains/soma:dev .` | The node image | Docker |

Script env: `DB_CONTAINER` (default `tinybrains-db-1`), `DB_USER`, `BASE`,
`SMOKE_HANDLE`, `SOMA_ENV_FILE` (smoke; default `../web/.env`), `ORION_ADMIN`,
`ORION_ADMIN_API_KEY` (load-package).

## Configuration

Environment is read by [`docker/entrypoint.sh`](docker/entrypoint.sh), the instance template
[`docker/soma.toml.tmpl`](docker/soma.toml.tmpl), the connectors and `scripts/load-package.sh`. Web's
compose file sets every one of them for the local stack.

| Variable | Default | Purpose |
|---|---|---|
| `SOMA_DB_URL` | required | Platform database as its owner (`soma-db`: routes and clocks) |
| `RUNNER_GATE_DB_URL` | required | Same database as `runner_gate` (`soma-db-gate`: the gate's match statements) |
| `ORION_STATE_DB_URL` | required | Orion's own state, database `orion_state` |
| `REDIS_URL` | required | Cluster state |
| `SOMA_DB_MAX_CONNECTIONS`, `SOMA_GATE_DB_MAX_CONNECTIONS` | 8, 4 | `soma-db` and `soma-db-gate` pool sizes |
| `SOMA_DB_CONNECT_TIMEOUT_MS`, `SOMA_GATE_DB_CONNECT_TIMEOUT_MS` | 5000 | Dial deadline **and** the pool wait: sqlx takes it as `acquire_timeout` |
| `SOMA_STATE_DB_MAX_CONNECTIONS`, `SOMA_STATE_DB_MIN_CONNECTIONS` | 15, 2 | Orion's own state pool (`[storage]`) |
| `SOMA_STATE_DB_ACQUIRE_TIMEOUT_SECS` | `10` | How long a request waits for a state connection |
| `SOMA_CRON_WORKERS` | `4` | How many clocks may run at once; never below the number that can be due together |
| `ORION_ADMIN_KEY` | required | Admin API key (`[admin_auth]`). Required by name: an unset or empty value stops the boot saying so |
| `TB_TRUST_PUBLIC_KEY` | required | Ed25519 key plugin signatures must verify under |
| `SOMA_SESSION_SECRET` | required | HS256 for session cookies and OAuth state, at least 32 bytes |
| `RUNNER_TOKEN_SECRET` | required | HS256 for runner tokens; a different key from the session one |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | required | The OAuth App |
| `R2_ENDPOINT`, `R2_BUCKET` | required | Replay bucket, at the address a **browser** fetches a replay from (presigned GET only) |
| `R2_ACCESS_KEY`, `R2_SECRET_KEY` | required | Object-store credentials for both buckets |
| `MODELS_BUCKET` | required | Models bucket |
| `MODELS_ENDPOINT` | required | Models bucket as **the node** dials it: HEAD, manifest GET |
| `MODELS_PUBLIC_ENDPOINT` | required | Models bucket as **a competitor** reaches it; submission PUTs are signed for it |
| `RUNNER_BLOB_ENDPOINT` | required | Object store as **a runner** dials it; replay PUTs are signed for it and it must equal the runner's `kalam-blobs-put` base |
| `APP_URL` | `http://localhost:5173/` | Where sign-in returns; an allowed `?next=` origin |
| `OAUTH_REDIRECT_URI` | `http://localhost:5173/v1/auth/github/callback` | Exactly as registered with GitHub; https except on loopback |
| `CONSOLE_URL` | `http://localhost:8081` | The Orion console, the second allowed `?next=` origin |
| `SOMA_COOKIE_SECURE` | `1` | `0` only for a plain-http stack |
| `SOMA_TRUSTED_PROXIES` | the RFC1918 ranges | TOML array of proxies whose `X-Forwarded-For` is believed |
| `SEASON_GAP_DAYS` | `1` | Minimum days from a close to the next season's opening |
| `SOMA_ADMIN_GITHUB_IDS` | empty | GitHub numeric user ids, comma-separated, made admins at every sign-in; the node refuses to start on anything else |
| `ORION_CLUSTER_ENABLED`, `ORION_INSTANCE_ID` | `true`, empty | Cluster mode; a stable id per node |
| `ORION_VERSION` | `1.9.0` | Recorded on every verdict and match as `orion_version` |
| `ORION_SHUTDOWN_DRAIN_SECS`, `ORION_SHUTDOWN_FORCE_SECS`, `ORION_CRON_SHUTDOWN_SECS` | 30, 30, 60 | Shutdown bounds |
| `PLUGIN_SIG_DIR` | none | `<component>.sig` files for tb.rating, tb.pairing and tb.ants |
| `SOMA_ALLOW_PRIVATE_URLS` | `false` | `[vars] allow_private_urls`, which every connector but `soma-cache` reads: compose service names resolve to private addresses |
| `SOMA_CACHE_URL` | *(required)* | `soma-cache`'s Redis, the response cache for the anonymous reads. An absent `env://` skips the connector |
| `SOMA_HOT_CACHE_TTL_SECS`, `SOMA_SEASON_CACHE_TTL_SECS` | 10, 60 | How long an anonymous read is served from `soma-cache` |
| `SOMA_RATE_*_RPS`, `SOMA_RATE_*_BURST` | as shipped | One pair per rate-limit family (`public`, `session`, `per_user_read`, `per_user_write`, `per_admin_board`, `runner`, `runner_token`, `per_runner`, `signin`); `docker/soma.toml.tmpl` lists them |
| `GITHUB_API_BASE` | api.github.com | Load-time connector base |
| `SOMA_ARTIFACT` | `/var/lib/orion/soma.package.json` | Where `serve` compiles the package to, and what `[packages] apply` reads |
| `SOMA_ADMIN_DB_URL` | bootstrap, required | The maintenance database (`.../postgres`), for `CREATE DATABASE orion_state` |
| `RUNNER_GATE_DB_PASSWORD`, `KALAM_DB_PASSWORD` | bootstrap; first required | Role passwords; the migration creates both roles with none |
| `ENGINE_RELEASE` | bootstrap, `0` | `1` declares the engine as a release instead of a patch |
| `GAME` | `ants` | The game bootstrap registers |

**Node sizing.** Every pool, rate limit and cache TTL is a `[vars]` entry the definitions read as
`var://`, not a literal in the package: a var keeps its declared TYPE, which an `env://` (always a
string) cannot. **The Postgres budget is `SOMA_DB_MAX_CONNECTIONS + SOMA_GATE_DB_MAX_CONNECTIONS`
against `soma`, plus `SOMA_STATE_DB_MAX_CONNECTIONS` against `orion_state` — 27 as shipped**, plus a
transient `psql` or two while `bootstrap` runs. Shrink the pools before the cron workers: five clocks
are declared and `soma-clock-admit` holds a worker for as long as its 600 s timeout, so fewer workers
than clocks that can be due together is an idle ladder on a node whose `/readyz` says ok. The
response-cache TTLs are the lever that takes load off the pools and the node at once.
`scripts/check-names.sh` refuses a `var://` name `[vars]` does not declare — Orion's own rule reads
workflow logic and not a connector's config, so that one is checked here.

**Build args:** `ANTS_RELEASE` (empty is the latest ants release; the cartridge, reference set,
engine digest and component come from it), `ORION_VERSION` (1.9.0), `RUST_VERSION`,
`WASM_TOOLS_VERSION`, `CURL_VERSION`, `DEBIAN_VERSION`. **Policy numbers** (pairing, rating,
admission, runner contract) are `[vars]` in `docker/soma.toml.tmpl`, and most can be overridden per
season through its `rules` document (`season_rule_spec()` in
[`migrations/0001_init.sql`](migrations/0001_init.sql) is the list).

## Operating a season

1. **Create it** (`POST /v1/games/{game}/seasons` or the admin page). The name gives the slug, and
   neither ever changes. It is refused while another season of the game is live or inside
   `SEASON_GAP_DAYS` of the last close, and it pins `games.active_engine_digest`. Window, rules and
   classes stay editable only until it opens.
2. **Check its boards** with `tinybrains maps check <board.json>...`, which runs the same envelope
   and `worldgen` checks as the upload.
3. **Upload boards and baselines.** Both land disabled. Each map file is one `POST .../maps`;
   `PATCH` `{"enabled": true}` puts it in play and re-runs the engine check under this node's engine
   (refused `engine_mismatch` when the node and the season disagree). A baseline is
   `POST .../baselines` plus two uploads; the admit clock admits it like a submission and lands it
   `disabled`; enabling seeds its ratings at the prior. The season's admin page does all of this.
   **Nothing pairs** until a board is enabled, and no trial pairs until a baseline is enabled.
4. **While it runs**, boards and baselines can be enabled and disabled. A disable cancels the
   pending matches on it, while claimed and running ones finish and count.
5. **Close it.** The withdraw clock closes a season once its window has closed and every version has
   settled (`closure.policy` `settle`, the default), after `settle_grace_days` (`deadline`), or only
   on request (`admin`). `POST .../close` records a request; within the minute the close rejects
   versions still waiting (`SEASON_CLOSED`), cancels the queue and lets running matches count.
6. **Change the engine.** `bootstrap` from an image on a new ants release declares a **patch** by
   default: the game and the live season take the new digest, pending rows are re-stamped and the
   roster epoch bumps. `ENGINE_RELEASE=1` declares a **release**, refused while a season is live: a
   rules change waits for the next season. A runner on any other digest claims nothing.
7. **After the close**, push the season's boards and recipes from `tinybrains/maps/` to the backup
   repository. They are in no repository or release while the season runs.

Admins are `users.role = 'admin'`. The first is the deployment's: `SOMA_ADMIN_GITHUB_IDS` lists GitHub
numeric ids, and a listed account is made an admin each time it signs in (web's
`scripts/setup/admin-user.sh <login>` looks an id up). An id, never a login: GitHub frees a renamed
login for anyone to register. Every other admin is made and unmade by an admin on the Users admin
page (`PATCH /v1/admin/users/{id}`), which refuses a caller's own role so there is always one left,
and tells the account and every other admin. A demotion is immediate; a listed account is restored by
its next sign-in, so removing someone for good means removing their id too.

## Production requirements

- **The models bucket needs a CORS rule** allowing `PUT` from the site's origin: `/submit` uploads
  from the browser. MinIO answers preflights by default, and R2 and S3 do not. Verify from a browser,
  because `curl` sends no `Origin`.
- **`models/*` public-read, replays private**, and a lifecycle rule expiring `replays/` by age.
- **One bucket for uploads and nodes.** A node reading a different bucket from the one Soma signed
  the upload for rejects every submission `ARTIFACT_MISSING`.
- **Cluster mode whenever N > 1**: two nodes on two state databases are two schedulers, so each
  clock runs twice (fenced, but not once). Channel rate limits then live on Redis and are fleet-wide.
  `[rate_limit]` limits and `max_concurrent_per_node` stay per node.
- **Alert** on `/health` `config_propagation = degraded` and `orion_errors_total{reason="config_epoch_bump"}`.
- **Give the response cache its own Redis** (`SOMA_CACHE_URL`). Sharing one with cluster
  state means no eviction policy can trim the cache without evicting the clocks' coordination.
- **TLS**: `SOMA_COOKIE_SECURE=1`, and an https `OAUTH_REDIRECT_URI` (Orion refuses http off
  loopback).
- **Never expose port 8080 beyond the proxy.** It carries the admin API and `/metrics`.
  `admin_auth` is on, and `/health` detail needs the key.
- **An admitting runner, somewhere.** Soma runs no model, so a submission waits in `testing` until
  a kalam runner with `RUNNER_ROLE=admit` claims it (`--profile admit` in kalam's compose files). One
  per deployment is enough; run it on the Orion `orion_version` names, or the claim refuses it.
- **Non-empty trust keys** and plugins signed by web's `scripts/setup/sign-plugins.sh` for every new
  image, or the boot apply stops the node on a quarantined channel.
- **Narrow `SOMA_TRUSTED_PROXIES`** to the proxy actually in front. Empty, every browser shares one
  rate-limit bucket. Too wide, anyone inside the range can claim any address.
- **Role passwords** (`RUNNER_GATE_DB_PASSWORD`, `KALAM_DB_PASSWORD`) come from a secret store.
- **`SOMA_ADMIN_GITHUB_IDS`** holds the owner's GitHub numeric id and nothing more. Empty, nobody
  can reach an admin page; every other admin is granted on the Users page.
- **Scale runners on demand, never on queue depth.** Pair caps the queue at `pair_depth_target`, so
  a scaler reading depth caps the fleet at `pair_depth_target` over a runner's lanes and looks
  correct doing it. Demand is what pair itself reads (`sql/soma-clock-pair-run-demand.sql`): the
  seats the roster wants, which LEAD the queue -- a runner is wanted before the rows it will claim
  exist. The fleet is about `(demand + outstanding) / lanes`, where lanes is a runner's
  `RUNNER_CRON_WORKERS`, plus one runner while the oldest `pending` row has waited too long. Count
  only the live season's rows on its own `engine_digest`, or a rolling engine change asks for
  runners to drain rows nothing will claim.
- **Timeouts:** a channel's `timeout_ms` bounds a whole run (admit: 600 s for up to `admit_batch`
  submissions), `admit_timeout_s` (180 s) bounds this clock's hold on one submission before another
  run may re-claim it, and `admit_lease_s` (600 s) bounds an admitting runner's.

## Releasing

```sh
gh workflow run release.yml               # rehearsal: both platforms built and diffed, nothing pushed
git tag v0.2.0 && git push origin v0.2.0  # from main: ghcr.io/tiny-brains/soma:0.2.0, :0.2, :latest
```

The workflow builds on arm64, and the plugins, cartridge and orion-server download are built once
on the build platform, so the amd64 and arm64 images carry identical components and one signature
verifies on both. The ants release is the repository variable `ANTS_RELEASE`, or the latest, and
is recorded as the label `dev.tinybrains.ants.release`. **Under a live season, pin
`ANTS_RELEASE`**: a Soma and a runner built from different releases are two engines. A tag is never
re-cut. After a new image, re-sign the plugins.

## Layout

```text
Dockerfile                  the node image: plugins, the ants cartridge and component, orion-server, the package
docker/entrypoint.sh        `serve` and `bootstrap`
docker/soma.toml.tmpl       the instance config, cluster mode, and every [vars] policy number
.github/workflows/release.yml  a v* tag publishes the image for amd64 and arm64
channels/soma-*.json        routes: method, path, auth, rate limits, cache
workflows/soma-*.json       their task lists and inline SQL; each `description` carries the route's reasoning
channels/soma-clock-*.json   the five clocks; their task lists are workflows/soma-clock-*-run.json
connectors/                 soma-db, soma-db-gate, soma-cache, soma-github, soma-blobs (replay GET),
                            soma-blobs-gate (replay PUT), soma-models (public: upload PUT),
                            soma-models-internal (HEAD + GET), soma-models-http
shared/soma.json            constants and fragments the set references with $from and use
plugins/                    tb-rating and tb-pairing (one cargo workspace) and build.sh
migrations/0001_init.sql    tables, constraints, shared functions, roles and grants
migrations/0002_sessions.sql  sessions, live_sessions, notifications, notification_settings
sql/                        every statement over ~240 characters, one file each; the workflows
                            name them with {"$sql": "../sql/<name>.sql"} and compile inlines them
scripts/load-package.sh     compile and apply a working copy into a running node; --prune retires
                            what a version dropped. A node's own [packages] apply does the boot
scripts/check-defs.sh       no-stack gate
scripts/check-names.sh      the ids, the tags and the sql/ filenames; run by check-defs.sh
scripts/check-sql.sh        orion-server sql check, as each connector's role
scripts/smoke.sh            every route, against a running stack
scripts/verify/             run.sh (reads the shipped statements), statements.sql (only what does
                            NOT ship), scenario.sql, the race files
```

## Invariants

- **Only count writes a rating**, and every ladder write re-reads count's run fence `FOR SHARE`.
  Routes and clocks share the owner role, so this is a review boundary, not a grant.
- **Pair's insert derives everything and trusts nothing**: it checks the roster epoch, takes the
  seat count from an enabled board of the live season, and refuses self-pairing unless the season
  allows it. A stale plan inserts nothing.
- **Admission writes only under its `admit_token`**, and an attempt is a runner's claim. A
  submission waiting for a runner, or for this clock over a fault of its own, spends nothing; a
  report that decided nothing keeps the attempt its claim spent, so one that fails the same way on
  every runner expires `TIMED_OUT` instead of retrying every tick.
- **A runner executes admission and never decides it.** The registration is rebuilt here, the report
  is typed by `admission_facts()` before anything binds it, and `runner_gate` can write an
  admission's claim and report and no verdict column.
- **Trials feed no ladder**, and a loss alone never rejects a candidate.
- **A trial is live until count decides it**, `finished` included, in pair's read exactly as in
  `matches_one_live_trial_uniq`. A pair run that offered a second trial would die on the index.
- **A refusal is the fleet's, never the candidate's.** The gate fails a row `MODEL_UNAVAILABLE` only
  once the ceiling is spent and the row has waited `refusal_grace_secs` since it was paired, and a
  refused trial spends no repair: it has a ceiling of its own, which rejects `RUNNER_UNAVAILABLE`,
  never `UNPLAYABLE`.
- **A shape many routes return is defined once, in the migration** (`season_json`, `season_state`,
  `current_season`, `model_phase`, `model_ratings`, `ladder_field`, `match_seat_rows`, the
  `season_admits*` predicates). A second copy is two pages that disagree.
- **Weight classes are the season's and strictly ascending.** Admission takes the first class a
  size fits.
- **The schema is two files, rewritten in place, and must pass kalam's `check-sql.sh` too.**
- **A notification is never part of the statement that decided the thing**, and is keyed so a
  replay inserts once.
- **Revocation is a JOIN inside the statement** (`live_sessions`, `live_runners`), never a guard task
  and never trust in a signed token.
- **The runner routes run as `runner_gate`.** A statement that needs a grant is on the wrong
  connector. Never widen `kalam`.
- **The gate's match statements live here**, and `verify/run.sh` refuses drift. Kalam's db-mode
  copies in `kalam/sql/tb-match-run-*.sql` are unchecked and change together with these.
- **A gate route's `data.req.*` field names are the contract** with Kalam's runner.
- **`finish` tells a duplicate delivery (200) from a lost claim (409).** Conflating them fails a
  healthy runner.
- **Every definition carries three tags, `[package, surface, domain]`**, in that order --
  `["soma", "gate", "matches"]`. `?tag=` is an EXACT, SINGLE-TAG match with no prefix and no AND,
  and no list page searches names or ids, so the tag filter is the navigation and each tag has to
  be a useful question on its own. The surface is one of `pub`, `user`, `admin`, `gate`, `clock`
  (`conn` on a connector) and is also the id's second segment; `scripts/check-names.sh` DERIVES it
  from the definition and fails if the two disagree. The domain comes from a closed list of
  thirteen, shared with kalam -- web's `scripts/check/configs.sh` compares them.
- **Only caller-invariant routes cache.** The cache key has no caller in it. A route that carries
  the live season (`/v1/games`, `/v1/games/{game}`, the seasons list) takes `season_cache`, 60 s,
  so an admin's change reaches every reader within a minute and the three never disagree.
- **Something private gets its own path** (`/v1/me/matches`), never a parameter on a public route.
- **The board and the terms of play ride the claim.** A runner fetches no board and holds no copy of
  `turn_ms`.

## Known gaps

- Notifications are never pruned. No clock may delete, so pruning needs a writer that is not a clock.
- Push notification settings are stored, but nothing delivers them.
- The refusal grace runs from when a row was paired, not from when a runner arrived: a runner that
  starts cold against rows older than `refusal_grace_secs` can still fail them `MODEL_UNAVAILABLE`
  before its roster catches up. A refused row is claimed after the fresh rows of its kind, which
  spreads the refusals; trials still come before every ranked match.
- A `failed` match notifies nobody. The gate writes it as `runner_gate`, which must not gain the grant.
- A broken adapter is not rejected as one. An inference that fails outright on the admitting runner
  is reported as a probe that errored, which cannot be told from a runner's own failure, so the
  report goes back to the queue and the version expires `TIMED_OUT` rather than `ADAPTER_INVALID`.
- Admission plays the first `admit_observations` (64) reference observations, each under a fixed
  `admit_infer_ms` that is not sized from the season's `turn_ms`. A model that is legal at play but
  slower than that errors here on every runner and expires.
- A registration the admitting runner's node refuses (400) reads as `ADMISSION_UNREACHABLE`:
  `http_call` writes nothing on a 4xx, so the runner cannot tell a refusal from an outage. It costs
  an attempt each time and expires `TIMED_OUT` rather than being refused with a reason.
- An admitting runner's report is judged, not re-derived. The size is measured here too, but the
  operator set, opset, parameter count and probe tally are the runner's word. Every runner key is an
  admin's, and a runner key can already report a match result.
- Nothing tells an admin that no admitting runner is up. Submissions wait in `testing` (phase
  `queued`) for as long as there is none, spending no attempt.
- The OAuth callback cannot say which failure happened: `oauth2_login` answers a fixed 401.
- No API tokens for an SDK or CLI.
- `finish` has no `turns <= max_turns` gate (`max_turns` is a season rule, so it needs the claim's coalesce).
- The revalidation sweep is unbuilt: `revalidate_batch` is read by nothing, so a version admitted
  under an older `orion_version` is never re-checked.
- Retention beyond traces is unbuilt, and so is the TinyBrain Index (`standings.lambda` is accepted and unread).
- A season cannot be scheduled ahead: create is refused while one is live.
- An off-site runner must hold a GET key for the models bucket. The fix is an Orion ask, not yet
  filed: a URL-valued artifact reference on the `models` entity.

## License

Apache-2.0: see [LICENSE](LICENSE).
