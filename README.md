# soma

Soma is TinyBrains' public API, its schema and the life cycle of a model version: sign-in,
submissions, admission, trials, promotion, pairing, rating and seasons. It is an Orion 1.8.1 package
(REST channels, cron clocks, workflows, connectors and two Rust/wasm plugins) plus the Postgres
migrations every package shares, shipped as the node image `ghcr.io/tiny-brains/soma`.
[Kalam](https://github.com/Tiny-Brains/kalam) runners play the matches Soma queues, and
[web](https://github.com/Tiny-Brains/web) is the site in front of it and the local stack.

**Owns:** GitHub sign-in and sessions · public reads · submissions and their presigned uploads ·
seasons, their boards and baselines · admission, pairing, trials, promotion, rating, withdrawal and
the season close · the runner gate `/v1/runner/*` · notifications · the schema and the `kalam` /
`runner_gate` grants. **Does not:** play matches or write replays (Kalam) · run models outside
admission (each node's Orion `models` entity) · implement game rules (the Ants cartridge) · decide
deployment addresses, credentials or replica counts.

```text
browser ──▶ web nginx ──/v1/──▶ ┌── Soma node × N (Orion, cluster mode) ────────────────┐
Kalam runner ──/v1/runner/*───▶ │ routes · runner gate · clocks · tb.rating · tb.pairing │── SQL ──▶ Postgres
                                │ tb.ants (map checks) · models entity (admission only)  │
                                └──┬─────────────────────┬───────────────────────────────┘
                     presign PUT/GET│                     │ HEAD + GET the manifest; the node fetches by digest
competitor ──presigned PUT──▶ models bucket (public-read) ◀── runners fetch by digest
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

`/v1/admin-check` exists for nginx `auth_request` (web puts the Orion console behind it): 2xx allows,
401 sends the caller to sign in, 403 refuses. Keep the 401/403 split. `tb-probe` also registers
`POST /internal/probe/adapter`, but only for the admit walk's `channel_call`: its `probe_auth` names
an audience nothing mints, so every HTTP caller gets 401, and `smoke.sh` asserts it. The port also
serves Orion's admin API, `/health`, `/readyz` and `/metrics`. Only `/v1/` may be proxied.

## Clocks

Generated by [`scripts/gen-clocks.py`](scripts/gen-clocks.py) into `channels/tb-*.json` and
`workflows/tb-*.json`. Each is a `forbid` singleton on its own key with the `latest` misfire policy;
the singleton buys order, and the SQL fences buy correctness.

| Channel | Every | Timeout | Does | Fence |
|---|---|---|---|---|
| `tb-admit` | 20 s | 600 s | Expire, claim `testing` versions, run the admit walk, write one verdict each | per-row `admit_token` claim |
| `tb-pair` | 15 s | 60 s | Read demand, fill the room with the plugin's plan, insert trials first | roster epoch, checked `FOR SHARE` per insert |
| `tb-count` | 10 s | 60 s | Fold finished matches in finish order, decide trials, promote | run fence on `clocks.count` |
| `tb-withdraw` | 60 s | 30 s | Cancel queue rows that can no longer be played; close the season | none: idempotent |
| `soma-runner-reap` | 5 s | 10 s | Return lapsed leases to `pending`; the third lapse fails the row | none: idempotent |
| `tb-probe` | — | 120 s | Not a clock: runs `model_infer` over the game's reference observations | — |

**Version life cycle:** `testing` → admit → `verified` → trial (count) → `active` → `superseded`,
or `rejected` at either step. A baseline goes `testing` → `disabled` ⇄ `active`. **Plugins:**
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
| `./scripts/check-defs.sh` | Generator `--check`, `orion-server lint`, `clippy`, `fmt --check` (all `--deny-warnings`), the Bearer-space check | `orion-server` 1.8.x |
| `python3 scripts/gen-clocks.py [--check]` | Regenerate (or check) the clock files, formatted by `orion-server fmt` | `orion-server` 1.8.x |
| `cargo test --manifest-path plugins/Cargo.toml` | Rating and pairing host tests | stable Rust |
| `plugins/build.sh tb-rating` (or `tb-pairing`) | Tests, then the wasm component and `plugin.json` beside the source (gitignored) | `wasm32-unknown-unknown`, `wasm-tools`, Python 3.11+ |
| `./scripts/check-sql.sh` | `PREPARE` every shipped query, task groups included, against a scratch schema; fails a description over 2048 chars | `tinybrains-db-1` up |
| `./scripts/verify/run.sh` | What the statements mean: the scenario walk, both fence races, that the migrations seed nothing an admin makes, the `kalam` grants; refuses if its statement copies drift from what ships | `tinybrains-db-1` |
| `./scripts/smoke.sh` | Every route's status code with a minted session, against the newest season (create one first); an admin handle adds a runner-key → token → claim round trip | the running stack, package loaded |
| `./scripts/load-package.sh` | Stage, compile, attach signatures, retire what is no longer shipped, `package apply` | `orion-server`, the admin API |
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
| `RUNNER_GATE_DB_URL` | required | Same database as `runner_gate` (`soma-runner-db`: the gate's match statements) |
| `ORION_STATE_DB_URL` | required | Orion's own state, database `orion_state` |
| `REDIS_URL` | required | Cluster state |
| `ORION_ADMIN_KEY` | required | Admin API key (`[admin_auth]`), also used by the self-load |
| `ORION_ADMIN_BEARER` | required | `Bearer <ORION_ADMIN_KEY>`, the whole header value, for the admit walk's `soma-node-admin` |
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
| `ORION_VERSION` | `1.8.1` | Recorded on every verdict and match as `orion_version` |
| `ORION_SHUTDOWN_DRAIN_SECS`, `ORION_SHUTDOWN_FORCE_SECS`, `ORION_CRON_SHUTDOWN_SECS` | 30, 30, 60 | Shutdown bounds |
| `PLUGIN_SIG_DIR` | none | `<component>.sig` files for tb.rating, tb.pairing and tb.ants |
| `SOMA_ALLOW_PRIVATE_DB` | `0` | `1` sets `allow_private_urls` on the database, bucket and admin connectors (compose service names are private) |
| `SOMA_CACHE_REDIS_URL` | `redis://redis:6379/1` | Response cache for the anonymous reads |
| `SOMA_NODE_ADMIN`, `GITHUB_API_BASE` | this node, api.github.com | Load-time connector bases |
| `SOMA_SELF_LOAD` | `1` | `0` starts the node without loading the package |
| `SOMA_ADMIN_DB_URL` | bootstrap, required | The maintenance database (`.../postgres`), for `CREATE DATABASE orion_state` |
| `RUNNER_GATE_DB_PASSWORD`, `KALAM_DB_PASSWORD` | bootstrap; first required | Role passwords; the migration creates both roles with none |
| `ENGINE_RELEASE` | bootstrap, `0` | `1` declares the engine as a release instead of a patch |
| `GAME` | `ants` | The game bootstrap registers |

**Build args:** `ANTS_RELEASE` (empty is the latest ants release; the cartridge, reference set,
engine digest and component come from it), `ORION_VERSION` (1.8.1), `RUST_VERSION`,
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
- **Give the response cache its own Redis** (`SOMA_CACHE_REDIS_URL`). Sharing one with cluster
  state means no eviction policy can trim the cache without evicting the clocks' coordination.
- **TLS**: `SOMA_COOKIE_SECURE=1`, and an https `OAUTH_REDIRECT_URI` (Orion refuses http off
  loopback).
- **Never expose port 8080 beyond the proxy.** It carries the admin API, `/metrics` and
  `/internal/probe/adapter`. `admin_auth` is on, and `/health` detail needs the key.
- **Non-empty trust keys** and plugins signed by web's `scripts/setup/sign-plugins.sh` for every new
  image, or the self-load stops the node.
- **Narrow `SOMA_TRUSTED_PROXIES`** to the proxy actually in front. Empty, every browser shares one
  rate-limit bucket. Too wide, anyone inside the range can claim any address.
- **Role passwords** (`RUNNER_GATE_DB_PASSWORD`, `KALAM_DB_PASSWORD`) come from a secret store.
- **`SOMA_ADMIN_GITHUB_IDS`** holds the owner's GitHub numeric id and nothing more. Empty, nobody
  can reach an admin page; every other admin is granted on the Users page.
- **Scale runners on demand, never on queue depth**: pair caps the queue at `pair_depth_target`.
  `scripts/autoscaler.sql` is pair's own demand statement plus the scaling arithmetic, generated by
  `gen-clocks.py` and prepared by `check-sql.sh`; its header lists the nine parameters.
- **Timeouts:** a channel's `timeout_ms` bounds a whole run (admit: 600 s for up to `admit_batch`
  submissions), and `admit_timeout_s` (180 s) bounds one submission before another run may re-claim it.

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
channels|workflows/tb-*.json  the clocks and tb-probe (generated; never edit by hand)
connectors/                 soma-db, soma-runner-db, soma-cache, github-api, soma-blobs (replay GET),
                            soma-runner-blobs (replay PUT), soma-models (public: upload PUT),
                            soma-models-internal (HEAD + GET), soma-models-http, soma-node-admin
shared/soma.json            constants and fragments the set references with $from and use
plugins/                    tb-rating and tb-pairing (one cargo workspace) and build.sh
migrations/0001_init.sql    tables, constraints, shared functions, roles and grants
migrations/0002_sessions.sql  sessions, live_sessions, notifications, notification_settings
scripts/gen-clocks.py       the clocks' readable SQL and task graphs, and scripts/autoscaler.sql
scripts/load-package.sh     stage, compile, sign, retire, apply (with stage-set.py)
scripts/check-defs.sh       no-stack gate (with check-auth-scheme.py)
scripts/check-sql.sh        PREPARE every shipped query
scripts/smoke.sh            every route, against a running stack
scripts/verify/             run.sh, statements.sql (copies of what ships), scenario.sql, the race files
scripts/autoscaler.sql      how many runners the ladder wants (generated)
```

## Invariants

- **Only count writes a rating**, and every ladder write re-reads count's run fence `FOR SHARE`.
  Routes and clocks share the owner role, so this is a review boundary, not a grant.
- **Pair's insert derives everything and trusts nothing**: it checks the roster epoch, takes the
  seat count from an enabled board of the live season, and refuses self-pairing unless the season
  allows it. A stale plan inserts nothing.
- **Admission writes only under its `admit_token`**, and a failure that is ours gives the attempt
  back. Otherwise an outage spends a competitor's tries.
- **Trials feed no ladder**, and a loss alone never rejects a candidate.
- **The generated clock files equal the generator.** `check-defs.sh` and `check-sql.sh` both fail on
  drift.
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
  copies in `gen-kalam.py` are unchecked and change together with these.
- **A gate route's `data.req.*` field names are the contract** with Kalam's runner.
- **`finish` tells a duplicate delivery (200) from a lost claim (409).** Conflating them fails a
  healthy runner.
- **Every definition carries `"tags": ["pkg:soma"]`**, or a deleted route keeps its path after
  the load.
- **Only caller-invariant routes cache.** The cache key has no caller in it.
- **Something private gets its own path** (`/v1/me/matches`), never a parameter on a public route.
- **The board and the terms of play ride the claim.** A runner fetches no board and holds no copy of
  `turn_ms`.

## Known gaps

- Notifications are never pruned. No clock may delete, so pruning needs a writer that is not a clock.
- Push notification settings are stored, but nothing delivers them.
- A `failed` match notifies nobody. The gate writes it as `runner_gate`, which must not gain the grant.
- The admit re-walk is not idempotent: a second attempt 409s on `register` and 404s on `activate`
  for a model this node already archived, and since the attempt is given back it never expires.
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
