# soma

Soma is the public API, the schema owner and the life cycle of a model version for TinyBrains:
admission, trials, promotion, matchmaking and rating. It ships an Orion 1.8.1 package of REST
channels, four cron clocks, workflows, connectors and two Rust-built WebAssembly plugins, plus the
Postgres migrations shared by the platform. It ships definitions and no server;
[DevOps](https://github.com/Tiny-Brains/devops) chooses the orion-server instances that host them.

**Until 16 September 2026 the clocks were a repository of their own, `jodi`.** It always loaded into
this package's Orion and read this package's `[vars]`, so the boundary bought nothing and cost a copy
of every loader and check script -- one of which had stopped seeing 14 of its 23 statements. Its
history is at [Tiny-Brains/jodi](https://github.com/Tiny-Brains/jodi), and its Status entries are
kept below under **Before the merge**.

## The name

The **soma** is a neuron's cell body. In TinyBrains, this package defines the durable data model
and the public access to it; the running API process itself is replaceable.

## Scope

**It owns**

- GitHub OAuth sign-in, session issuance, lookup, and revocation.
- Public game, model, match, season, and leaderboard reads.
- Submission recording and admin requests to open or close seasons.
- The platform migrations, constraints, and Kalam's restricted database grants.
- Signed read URLs for stored match replays.
- The runner gate: the match statements a Kalam replica plays through, and the keys that admit one.
- Admission verdicts based on the object in the bucket, the graph the node reads from it, and the manifest's adapters run over the game's reference observations.
- Opponent selection, map coverage, trials, and bounded queue generation.
- Rating folds, trial decisions, promotion, and predecessor replacement.
- Withdrawal of obsolete queued matches and completion of season closure.
- The database fences that protect those writes from stale clock runs.
- The notifications an account is told, written where each thing is decided, and the account's settings for them.

**It does not**

- Play matches or upload replays; [Kalam](https://github.com/Tiny-Brains/kalam) executes matches.
- Run models; Orion's own `models` entity evaluates a manifest's adapters and its ONNX graph on whichever node needs it.
- Fetch a competitor's bytes over the internet. The competitor uploads to a presigned URL this package mints, and the node's own `models` entity fetches, hashes, reads and probes.
- Set a game's execution budgets; the registered cartridge manifest supplies them.
- Implement game rules; [Ants](https://github.com/Tiny-Brains/ants) is the reference cartridge.
- Define deployment addresses, credentials, or replica counts.

## Where it sits

```text
[Browser / API client] -- HTTP /v1 ------------> [Soma routes] -- SQL --> [platform Postgres]
[Kalam replica, api mode] -- HTTP /v1/runner/* -->   |    |                   ^
                                                  OAuth  signed GET/PUT       | SQL, fenced
                                                     v    v                   |
                                               [GitHub] [object store]   [Soma clocks] --> [this node's models entity]
                                                                              |
                                                                              +--> [models bucket]
```

| Direction | Party | Over | What moves |
|---|---|---|---|
| called by | Web and API clients | HTTP /v1 | Queries, submissions, and session actions |
| reads | Postgres | soma-db SQL | Games, versions, results, ratings, and seasons |
| writes | Postgres | soma-db SQL | Users, sessions, submission records, and season requests |
| calls | GitHub | github-api HTTPS | OAuth exchange and account identity |
| calls | Replay store | soma-blobs signing | Time-limited GET URLs; no replay upload |
| reads | Postgres | soma-db SQL, from the clocks | Roster, seasons, manifests, demand, and completed results |
| writes | Postgres | soma-db SQL, fenced, from the clocks | Queue rows, ratings, events, version status, and season closure |
| calls | This node's admin API | soma-node-admin HTTP | Register a model by reference and digest, admit it synchronously, activate it for the probe, archive it after |
| calls | The models bucket | soma-models-internal signing + soma-models-http GET | HEAD the artifact, and read the manifest the competitor uploaded |

Kalam and the clocks coordinate through this schema and never call each other: a replica in `db`
mode over SQL, a replica in `api` mode through the runner gate's statements.
See the [system map](https://github.com/Tiny-Brains/devops#where-it-sits) for their placement.

## Interface

All paths below include the `/v1` prefix. Session routes verify the `soma_session` HttpOnly cookie
and use live database sessions; admin actions additionally require the user's current admin role.
[channels/](channels/) declares transport and authentication; [workflows/](workflows/) contains
request handling and response construction, with matching soma-prefixed filenames.

| Method | Path | Auth | Response or action |
|---|---|---|---|
| GET | /v1/auth/github | Public | Redirect to GitHub with state and PKCE |
| GET | /v1/auth/github/callback | Public OAuth callback | Complete sign-in and set the session cookie |
| GET | /v1/status | Public | Arena counters: queue, throughput, and what each clock is behind on |
| GET | /v1/games | Public | Registered games, each with its current season |
| GET | /v1/games/{game} | Public | One game: what it says about itself, its presets and limits, its season |
| GET | /v1/games/{game}/seasons | Public | Game seasons, with version and match counts |
| POST | /v1/games/{game}/seasons | Admin session | Create a season |
| PATCH | /v1/games/{game}/seasons/{number} | Admin session | Edit a season that has not opened |
| POST | /v1/games/{game}/seasons/current/close | Admin session | Request closure of the live season |
| GET | /v1/games/{game}/leaderboard | Public | Standings; ladder, season, limit, and cursor query parameters |
| GET | /v1/games/{game}/submission | Session | Whether the caller may submit, why not, and as which version |
| GET | /v1/models | Session | Caller's versions, with ratings and ranks; optional game filter |
| GET | /v1/models/{id} | Public | Version status, ladders with rank and field, and trial information |
| GET | /v1/matches | Public | A season's matches with every seat; or one model's, or one owner's. `players_min`/`players_max` bound the seat count |
| GET | /v1/matches/{id} | Public | Match details, seats, the ladders it counted on, and a signed replay URL |
| GET | /v1/profiles/{username} | Public | A competitor's public page: their versions by game and season |
| GET | /v1/me | Session | Current user and any candidate in flight; 401 when unauthenticated |
| PATCH | /v1/me | Session | Edit the display name |
| GET | /v1/me/matches | Session | The caller's matches in every state, queued and cancelled included |
| GET | /v1/me/notifications | Session | The caller's notifications, newest first: `category`, `unread`, `since`, `cursor`, `limit`, and the unread count across every category |
| POST | /v1/me/notifications/read | Session | Mark `ids`, or `all` (optionally one `category`), read; answers the unread count |
| GET | /v1/me/notification-settings | Session | One entry per category the caller can receive: `app`, `push`, `locked`, and `level` for matches |
| PATCH | /v1/me/notification-settings | Session | Change one category; answers the whole list. 409 `category_locked` for submissions or account turned off |
| GET | /v1/sessions | Session | The caller's live sessions |
| DELETE | /v1/sessions/{sid} | Session | Revoke one session; `others` revokes all but the current |
| DELETE | /v1/session | Session | Revoke the current session and clear the cookie |
| GET | /v1/admin-check | Session | **204 / 401 / 403 and no body.** An authorization probe for a reverse proxy, not a page |
| POST | /v1/submissions | Session | Record a release and declared asset hashes as a testing version |
| POST | /v1/runner-keys | Admin session | Mint a runner key; **the one response that carries it** |
| GET | /v1/runner-keys | Admin session | The caller's own keys, by prefix, with how many runners hold each |
| DELETE | /v1/runner-keys/{id} | Admin session | Revoke a key, and with it every machine started from it |
| GET | /v1/runners | Admin session | The fleet: last seen, engine digest, arch, in flight |
| DELETE | /v1/runners/{id} | Admin session | Stop one machine without touching its key |
| POST | /v1/runner/token | Public, IP-limited | Exchange a runner key for a ten-minute `aud: runner` token |
| POST | /v1/runner/claim | Runner token | One match and the contract to play it under, or `200 {"idle": true}` |
| POST | /v1/runner/matches/{id}/start | Runner token | claimed → running, on the claim token |
| POST | /v1/runner/matches/{id}/release | Runner token | Give the row back, spending a refusal |
| POST | /v1/runner/matches/{id}/renew | Runner token | Extend the lease on the **database's** clock |
| POST | /v1/runner/matches/{id}/replay-url | Runner token | A presigned PUT for this attempt's replay |
| POST | /v1/runner/matches/{id}/finish | Runner token | The row and all its seats, idempotently |
| GET | /v1/runner/roster | Runner token | Every version this machine should be able to play |

**The runner family is a second API on one hostname.** It verifies a bearer JWT with
`aud: "runner"` signed with `RUNNER_TOKEN_SECRET`, where browser sessions are cookie-borne and
signed with `SOMA_SESSION_SECRET` and carry no audience at all — so a stolen cookie is not a runner
and a stolen runner token is not a sign-in. It also needs its own rate limits:
`per_user_write_rate` is 1 rps and would strangle a claim loop on the first machine. There is one
cron channel, `soma-runner-reap`, singular because Soma's Orion runs in cluster mode -- the same reason
each of the four clocks below is. `docs/schema.md` §4 and §4a are the statements and the routes.

Read routes are public unless they can return something private. The split is a property of the
channel, never of a parameter: `GET /v1/matches` omits queued, cancelled and trial rows for
everyone, and `GET /v1/me/matches` is a separate route rather than `?owner=me`, because a public
route that quietly returns more to some callers is the shape a privacy bug arrives in.

A submission must satisfy the open season's rules. Recording it does not imply acceptance:
the admit clock performs admission, and count decides the trial before promotion. The callback is served by the sign-in
channel, so thirty-one routes are implemented by thirty channels.

> **This table is four rows short, and they are not new.** `channels/` carries
> `/v1/games/{game}/models` (POST), `/v1/models/{id}` (GET and PATCH) and `/v1/versions/{id}`,
> none of which appear above. Fix them against the channels rather than against this note;
> `ls channels/` is the inventory.

`/v1/admin-check` is the odd one and worth saying why it exists. It answers **204** for a signed-in
admin, **401** for no or a revoked session, **403** for a signed-in non-admin, and never a body —
which is exactly the vocabulary nginx's `auth_request` speaks, allowing on 2xx and denying on
401/403. It lets this platform put its own sign-in in front of something that is not Soma: today
the Orion console, which is a static SPA with nowhere to hold a credential
(`devops/compose/orion-ui/`). The 401/403 split is load-bearing there — 401 sends the caller to
GitHub, and answering it to a competitor who signed in correctly would loop them for ever.

Its workflow is a near-copy of `soma-seasons-create`'s first three tasks **on purpose**: the same
`JOIN live_sessions` is the same revocation check, and a second way of asking *is this an admin* is
a second thing to keep right. The role is read off the live session rather than off a claim in the
cookie, so demoting a user or revoking a session takes effect on the next request.

### The clocks

Four cron channels and one internal channel, generated by `scripts/gen-clocks.py` and committed as
`channels/tb-*.json` and `workflows/tb-*.json`. They have no public HTTP surface. Each clock has its
own `forbid` singleton and the `latest` misfire policy; the schedules are in the generator.

| Channel | Singleton key | One occurrence | Writes |
|---|---|---|---|
| tb-admit | admit | Claim testing versions and obtain admission facts | Model admission claims and verdicts |
| tb-pair | pair | Choose trials and regular matches within available queue room | matches and match_seats |
| tb-count | count | Fold results in finish order, decide trials, promote successors | ratings, rating_events, models, matches, clocks |
| tb-withdraw | withdraw | Cancel obsolete pending rows and close eligible seasons | matches, seasons, clocks |
| tb-probe | -- | Not a clock: the admit walk's `channel_call` target, one `model_infer` per reference observation | nothing |

| Plugin | Export | Computation | Determinism |
|---|---|---|---|
| tb.rating | tb.rating.trueskill | Rank-based TrueSkill factor-graph update per ladder | Pure arithmetic over supplied inputs |
| tb.pairing | tb.pairing.pair | Opponents, seats, maps, and match seeds | Pure; occurrence seed reproduces a plan |

The [rating manifest](plugins/tb-rating/plugin.toml) and
[pairing manifest](plugins/tb-pairing/plugin.toml) declare plugin inputs. Trial matches feed no
ladder; a successful trial establishes playability, not victory. The two plugins are one cargo
workspace, and their contracts check without running the clocks:

```sh
cargo test --manifest-path plugins/Cargo.toml
```

The migrations are also an interface. Apply both [0001_init.sql](migrations/0001_init.sql) and
[0002_sessions.sql](migrations/0002_sessions.sql); the table below describes writer ownership.

| Table or view | Purpose | Writers |
|---|---|---|
| users | Competitor identity, display name, and role | Soma sign-in and PATCH /v1/me; administrative provisioning for roles |
| sessions | Revocable sessions, with the browser and when it was last used | Soma |
| live_sessions | Unexpired, unrevoked session view | None directly; derived from sessions and users |
| games | Cartridge registration, its `about` copy, and current engine | Deployment registration |
| seasons | Competition windows, rules, weight classes, and engine identity | Soma admin routes; the withdraw clock's closure; deployment engine updates |
| models | Submitted versions and admission state | Soma inserts testing rows; the admit and count clocks admit and change roster status |
| matches | Queue, execution history, and count marker | The pair, count and withdraw clocks insert, count and cancel; Kalam executes |
| match_seats | Version snapshots and per-seat results | The pair clock inserts; Kalam records results |
| ratings | Per-version ladder state | The count clock |
| rating_events | Auditable before/after rating updates | The count clock |
| clocks | Run fences and roster epoch | The clocks; deployment bumps roster epoch on engine cutover |
| notifications | What an account is told, keyed per event so a replayed writer inserts once | The admit, count and withdraw clocks, sign-in, the runner token exchange; `read_at` by POST /v1/me/notifications/read |
| notification_settings | Only the categories an account changed; the rest are `notification_category_spec()`'s defaults | PATCH /v1/me/notification-settings |

Against the local DevOps instance, check the public route:

```sh
curl --fail --silent --show-error http://127.0.0.1:8080/v1/games
```

## Run it, test it

Soma needs Orion and a migrated database. The [DevOps setup](https://github.com/Tiny-Brains/devops#run-it-test-it)
provides both, plus replay storage and the browser proxy. Run package commands from this repo root.

- Orion server 1.8.1 and Postgres 16 for the supported local stack, with `[plugins]` and `[models]` enabled.
- curl plus jq or Python 3 for loading; Python 3 and Docker for the SQL check.
- An OAuth App for sign-in; its callback must point at the browser-facing origin.
- Stable Rust for the plugin tests; Python 3.11+, wasm-tools, and the wasm32-unknown-unknown target for a plugin rebuild.

After provisioning the runtime settings below and pointing ORION_ADMIN at that instance, load:

```sh
./scripts/load-package.sh
```

Check the definitions and their SQL:

```sh
orion-server --version
python3 scripts/gen-clocks.py --check # the committed clock files are what the generator writes
./scripts/check-defs.sh               # that, plus lint, clippy and fmt, all --deny-warnings
cargo test --manifest-path plugins/Cargo.toml
./scripts/check-sql.sh
./scripts/smoke.sh
./scripts/verify/run.sh
```

Edit a clock's SQL in `scripts/gen-clocks.py` and regenerate with `python3 scripts/gen-clocks.py`,
which formats what it writes with `orion-server fmt`. Rebuild a plugin with its own `build.sh`, or
`plugins/build.sh <name>`; both run the host tests first and write the component and the generated
plugin.json beside the source, neither of which is committed.

The SQL script prepares every shipped query -- task groups included -- against a scratch database
created from both migrations. It catches missing tables, columns, functions, and incompatible
parameters, but does not execute the REST workflows. It recreates soma_sqlcheck; set DB_CONTAINER
and DB_USER to a development Postgres container. `smoke.sh` covers the half it cannot: it calls
every route against a running stack and checks the status code, minting a real session row and
cookie so the authenticated routes are exercised rather than asserted to be 401, and putting back
what it borrowed. It is a status-code suite, not a behaviour one. `verify/run.sh` is the third:
what the statements mean, walked against a scratch schema, with both fence races and the Kalam
role exercised rather than asserted.

Package lint checks definition references. Orion clippy with the rendered instance configuration
also checks `[vars]`; validate-config checks the instance itself. The deployment must run all
applicable checks, because a successful package load alone does not prove a working session flow.

Use the pinned Orion 1.8.1 toolchain for these checks. Older binaries do not understand this
package's cron, plugin, or authentication definitions and can report misleading schema errors.

## What a deployment owes it

| Setting | Purpose | Missing or inconsistent value |
|---|---|---|
| SOMA_DB_URL | Secret-bearing platform database URL | Database-dependent routes cannot load or run |
| SOMA_SESSION_SECRET | Secret HS256/state key, at least 32 bytes | Sign-in and session routes cannot authenticate |
| GITHUB_CLIENT_ID | Public OAuth App identifier | Sign-in cannot reach the intended application |
| GITHUB_CLIENT_SECRET | Secret OAuth credential | Token exchange fails |
| R2_ENDPOINT, R2_BUCKET | Replay store location | Match reads cannot produce usable replay URLs |
| R2_ACCESS_KEY, R2_SECRET_KEY | Secret replay signing credentials | Signed replay access fails |
| app_url, oauth_redirect_uri | Orion vars for post-login destination and callback | Redirects target the wrong origin or callback registration fails |
| cookie_secure | Boolean Orion var for cookie transport | Must match HTTP development or HTTPS deployment |
| prior_mu, prior_sigma, settled_sigma | Orion vars for leaderboard priors, provisional status, and the clocks' initial ratings | One `[vars]` block serves the routes and the clocks, so there is nothing to keep equal |
| season_gap_days | Orion var for the minimum gap between seasons | Missing or incorrect policy changes season-opening eligibility |
| GITHUB_API_BASE | Load-script substitution for the github-api connector's base | Defaults to api.github.com; the connector serves sign-in and nothing else |
| ORION_ADMIN, ORION_ADMIN_API_KEY | Load-script destination and optional secret bearer token | Defaults target local admin; protected APIs require the token |
| SOMA_ALLOW_PRIVATE_DB | Loader flag, 1 for private database, bucket and admin addresses | Orion's private-address guard blocks those connections |
| MODELS_ENDPOINT, MODELS_BUCKET | The models bucket at its INTERNAL address, for soma-models-internal | The admit clock cannot HEAD an artifact or sign its manifest GET |
| R2_ENDPOINT (loader) | Also substituted into soma-models-http as its base | The connector keeps its placeholder and the manifest fetch 404s |
| SOMA_NODE_ADMIN | Loader substitution for soma-node-admin, the admin API admission registers a model on | Defaults to ORION_ADMIN, which is right on a node and wrong anywhere else |
| ORION_ADMIN_BEARER | The whole `Bearer <key>` header value soma-node-admin sends | Every admin call is 401: a connector resolves `env://` only when the reference is the entire string |
| PLUGIN_SIG_DIR | Loader: detached Ed25519 signatures for tb.rating and tb.pairing | A node with trust keys quarantines the clocks that call an unsigned plugin |
| game, presets | Ladder and map selection | Pairing has no valid selection context |
| count_batch, pair_depth_target, burst, steady_cap | Batch and demand controls | Defaults are not supplied by this package |
| cross_class_fraction, repair_cap | Pairing policy | Incorrect values alter coverage and demand |
| sigma_inflation | A successor's rating uncertainty | Inconsistent priors change ladder behavior |
| ts_beta, ts_tau, ts_draw_probability | Rating model parameters | Incorrect values change every fold |
| forfeit_strikes | Pair's fallback strike ceiling when a season declares none, stamped on `matches.strike_ceiling` | Missing, pair halts at its insert |
| admit_batch, admit_timeout_s, admit_attempts_max, admit_deadline_ms | Admission routing and claim policy | Missing values prevent reliable admission |
| opset_min, opset_max, op_allowlist | Admitted ONNX dialect | Incorrect values admit or reject the wrong graphs |

Orion also needs its own state storage, separate from the platform schema; DevOps supplies
ORION_STATE_DB_URL and cluster configuration. The [instance template](https://github.com/Tiny-Brains/devops/blob/main/orion/soma.toml.tmpl)
is the configuration reference, including session, quota, season, pairing, rating and admission
policy. Policy values are provisional deployment choices; `docs/config.md` names every tuning number
and what measures it. Multiple hosts share Orion cluster state so each clock stays a cluster-wide
singleton, while the SQL fences remain the correctness mechanism.
The browser origin, registered OAuth callback, and proxy must agree. Replay URLs must likewise
resolve from the browser, not only from containers.

## Layout

```text
channels/soma-*.json          HTTP paths, session auth, and quotas
channels/tb-*.json            the four clocks and the probe channel (generated, committed)
workflows/soma-*.json         request handling, inline SQL, and response mapping
workflows/tb-*.json           the clocks' task graphs (generated, committed)
connectors/soma-db.json       platform database connection, for the routes and the clocks
connectors/soma-runner-db.json  the runner gate's database connection, as runner_gate
connectors/github-api.json    GitHub API connection
connectors/soma-blobs.json    replay GET signing; PUT disabled
connectors/soma-models.json   the models bucket at its PUBLIC address: a competitor's presigned PUT
connectors/soma-models-internal.json  the models bucket at its INTERNAL address: HEAD + presign GET
connectors/soma-models-http.json  the object store over HTTP, for that presigned GET
connectors/soma-node-admin.json   this node's own admin API, for admission
shared/soma.json              constants and fragments the set references with $from and use
plugins/Cargo.toml            the two plugin crates as one workspace
plugins/build.sh              component and manifest build, shared by both
plugins/tb-rating/            TrueSkill source, tests, and manifest
plugins/tb-pairing/           seeded pairing source, tests, and manifest
migrations/0001_init.sql      platform tables, constraints, fences, grants, and the shared functions
migrations/0002_sessions.sql  sessions, live_sessions, notifications and notification_settings
scripts/gen-clocks.py         the clocks' generator and their readable SQL; `--check` catches drift
scripts/load-package.sh       compile, sign, retire what is no longer shipped, apply
scripts/check-defs.sh         generator drift, lint, clippy, fmt; no stack
scripts/check-sql.sh          preparation of every shipped query, task groups included
scripts/smoke.sh              every route called, against a running stack
scripts/verify/               the schema walk: the scenario, both fence races, the seed and the grants
docs/schema.md                the schema's design, and every statement the packages run
docs/clocks.md                the clocks: fences, loop shape, demand, pairing, promotion
docs/admission.md             the admit walk and its verdicts
docs/rating-and-seasons.md    ratings, ladders, and a season's life
docs/config.md                every tuning number, and what measures it
LICENSE                       repository licence
```

## What must stay true

- **No route writes a competitive result or a rating, and only count writes a rating.** Count's run fence is checked by every ladder-write statement it runs. Routes and clocks share `soma-db` and the owner role, so this is a review boundary, not a grant.
- **A stale pairing cannot revive an obsolete roster.** Pair's insert checks the roster epoch and derives authoritative seat data.
- **Admission verdicts belong to the current claim.** The per-version `admit_token` stops a timed-out run deciding a newer attempt.
- **Infrastructure failures do not spend competitor attempts.** Admission branches on whose fault it was and returns the attempt when the failure is ours.
- **Trials test playability.** A loss alone must not reject a candidate; trial matches produce no ladder fold.
- **The generated clock files are the installed package.** `check-defs.sh` and `check-sql.sh` fail when they do not match `scripts/gen-clocks.py`.
- **A shape many routes return is defined once, in the migration.** `season_json()` and `season_state()`, `model_ratings()`, `model_phase()`, `current_season()`, `match_seat_rows()` and the two `season_admits*()` rule predicates are where those shapes and judgements are built. Six routes return a season, three print "rank 6 of 47", three list a match's seats, and the submission rules are asked once by the insert that must not happen and once by the read that says why it did not. A second copy of any of them is a page that disagrees with another page, or a refusal whose reason denies it, with no way to notice.
- **A season owns its weight classes.** `seasons.weight_classes` is the only definition of what nano means; admission reads the version's own season and the book points readers at it. The column is validated strictly ascending, because admission takes the first class a size fits and an out-of-order table makes a class silently unreachable. The trade is deliberate: a class result is comparable within its season, not across seasons.
- **A game introduces itself.** The provenance copy, the presets and the limits come from the cartridge manifest through `GET /v1/games/{game}`, so a second game is a registration and not a web deploy. The fold in the cartridge's own `build.sh` admits named keys only, refuses a non-string and requires https: this document is rendered in a browser.
- **Migrations define one schema for all packages.** A schema change must pass each consumer's SQL check before deployment.
- **A notification never costs a decision.** Every writer is its own `continue_on_error` statement after the thing it reports -- never a CTE in a fenced fold, a verdict or a close -- reads the decision off the row, asks `notification_wanted()` inside its INSERT, and is keyed `ON CONFLICT (user_id, dedupe_key) DO NOTHING`. A run that dies between the two loses that notification; nothing can duplicate or invent one. `docs/schema.md` §3.11.
- **Revocation remains effective before JWT expiry.** Session workflows consult live_sessions rather than trusting a signed token alone.
- **Kalam's role stays limited to execution.** The migration enumerates its writable columns and creates no embedded password. **The runner routes do not run under it.** They are in this package, over `soma-db`, so they execute as the database owner and the column grant is not what stops one of them writing a rating — review is. That is the price of one package instead of two, it is written down on the grant block itself, and undoing it is a `soma-runner-db` connector on `env://KALAM_DB_URL` plus a one-word swap in eight workflows. A runner statement that needs a grant added to the `kalam` role is a statement on the wrong connector.
- **A runner holds no credential, and revocation is a JOIN.** It has no database URL and no write key: it gets a ten-minute token and presigned PUTs. Every match statement JOINs `live_runners`, *inside the statement and never as a guard task* — a JSONLogic guard fails open if it is ever wrong, and a JOIN cannot be forgotten — so a revoked key, a revoked runner or a demoted admin ends the next call rather than the next token.
- **The eight match statements have one home, and it is now this repository.** A route is a skin over a statement; a second copy of the claim's SQL anywhere is the bug the move was meant to prevent. `scripts/verify/run.sh` compares the harness's copies against the shipped workflows and refuses to run if they differ, because both this repo's copies were silently stale for months before it did. It compares its thirteen copies of the clocks' statements, and its five of the notification writers, the same way.
- **`finish` is idempotent under a duplicate delivery and fenced against a stale one**, and the two are distinguishable in the response. A route that conflates them fails a healthy runner mid-match.
- **Package reloads respect ownership tags.** load-package.sh retires only the pkg:soma objects the compiled artifact no longer carries -- routes, clocks, connectors and plugins alike -- and nothing tagged for Kalam. DevOps' loader sweeps the retired `pkg:jodi` tag off this node, so a deployment from before the merge sheds the old copies.
- **Cookie behavior remains deployment configuration.** No route should hard-code a callback host or replace the declared Secure policy.
- **Only a caller-invariant route may declare `cache`.** The response-cache key covers the method, the path params and the query — so two ids cannot collide — and covers *nothing about the caller*: no cookie, no claim. Caching an authenticated channel would serve one session's body to the next. The nine that cache are the nine anonymous reads; `soma-status` is anonymous too and stays uncached, because freshness is the whole answer it gives.
- **Every channel but one is metered twice.** `rate_limit` is the outer guard and runs *before* authentication, keyed on the caller's address; `principal_rate_limit` is the quota and runs after, keyed on `auth.sub`. A channel with only the second one meters nobody until they have signed in, which is the wrong order for an anonymous flood. The exception is `soma-admin-check`, whose caller is a proxy rather than a browser — its address is one container's, so an address-keyed bucket there could only ever lock the console out of itself. **The address is only as good as the deployment's `[rate_limit] trusted_proxies`**: with that list empty Orion keys on nginx and the whole internet shares one bucket.

## Status

**17 September 2026 — notifications.** An account is now told what the platform decided about it.
`notifications` and `notification_settings` are in `0002_sessions.sql`, beside `sessions`, with no
grant at all -- `kalam` and `runner_gate` gain nothing, and `verify/run.sh` asserts it by role,
table and privilege. `notification_category_spec()` is the one definition of the six categories,
which are locked (submissions, account), which is admin-only, and the defaults; the settings table
holds only what a competitor changed.

**Four routes**: `GET /v1/me/notifications`, `POST /v1/me/notifications/read`, and GET/PATCH
`/v1/me/notification-settings`. **Seven writers**, each keyed on its event and each a separate
`continue_on_error` statement after the decision it reports: a version's decided state (admission's
verdict in `tb-admit`, a trial's pass or rejection in `tb-count`, one statement), admission's expiry,
a rated result per seat by the `matches` level, a settled rank that moved (`tb-count`), a season
closed (`tb-withdraw`), a sign-in while another
session is live (`soma-auth-github`), and a runner reporting an engine no live season pins
(`soma-runner-token`, to the key's admin). `GET /v1/matches` gained `players_min`/`players_max`.

**One deciding statement changed:** admission's expiry stamps the run's own `admit_token` on the rows
it rejects instead of `NULL`, which is how `notify_expired` finds exactly those rows. Nothing reads a
token on a rejected row.

**Verified.** `check-defs.sh` clean at 49 channels, 49 workflows; `check-sql.sh` prepares 107
statements and kalam's passes; `verify/run.sh` compares five new statement copies with what ships and
walks every writer -- a result told once and only to a competitor, a pass and a trial failure told,
a superseded version not, a settled rank flip told and an unsettled one not, the expiry and the close
told once each -- with the same output as before otherwise. On the running stack, `smoke.sh` 66/66 as
an admin and 59/59 as a competitor; a three-competitor submission storm produced every admission,
rejection, trial and result notification the settings called for and none they did not, the
runner-token writer told an admin once across two exchanges, and every clock trace stayed clean.
**Not exercised live**: the sign-in writer through a real GitHub OAuth round trip (its statement was
run against the live database in a rolled-back transaction), a season close, a real expiry, and a
rank change on a settled ladder (all three walked in `verify/run.sh`).

**Open.** Retention: nothing prunes `notifications`, and no clock may; the DELETE needs a writer that
is not a clock. Push is a stored preference that nothing delivers. A match that **fails** tells
nobody: `failed` is written by the runner gate as `runner_gate`, which must not gain a grant, so that
writer would be a clock sweep. And a notification is lost if a run dies between a decision and its
notify -- the trade §3.11 of `docs/schema.md` argues for.

**16 September 2026 (merge) — the clocks are Soma's.** `jodi` is folded into this repository and its
package into this one: `channels/tb-*.json`, `workflows/tb-*.json`, `scripts/gen-clocks.py` (was
`gen-jodi.py`), `plugins/`, and `docs/{clocks,admission,rating-and-seasons,config}.md` (`clocks.md`
was `design.md`). The channel, workflow and plugin ids did not change, and neither did a single
statement: the regenerated files are semantically identical to what jodi shipped, apart from the
renames below.

**The `jodi` role is gone.** The clocks run over `soma-db` as the owner, which now pools 20
connections where the routes had 10 and the clocks another 10. `0001_init.sql` loses the role and
its grants, `check-sql.sh` loses the `SET ROLE jodi` pass and its absence checks, and "no clock
deletes, reads `sessions` or rewrites an entry" is a review boundary rather than a grant -- the same
trade the runner routes made before N17. Renamed: `jodi-models` → `soma-models-internal`,
`jodi-blobs-get` → `soma-models-http`, `jodi-orion` → `soma-node-admin`, `JODI_ORION_ADMIN` →
`SOMA_NODE_ADMIN`, `JODI_ALLOW_PRIVATE_DB` → `SOMA_ALLOW_PRIVATE_DB`, `pkg:jodi` → `pkg:soma`.

**What the merge found.** `jodi/scripts/check-sql.sh` walked only the top-level task list, so since
`group_runs()` landed on 15 September it had PREPAREd 9 of the clocks' 23 statements -- count's fence,
fold and pass, pair's demand and trials and admission's claim among the 14 it skipped. This repo's
walker already descended, and all 91 statements prepare. `scripts/verify/run.sh` now compares its
thirteen copies of clock statements with the generated workflows as it does Kalam's eight, and three
copies that no longer matched anything shipped -- `c_verdicts`, `c_decide` and `c_batch`, earlier
forms of what count reads as one document -- are replaced by `c_batch_doc`.

**The plugins did not move.** The image builds `tb-pairing` `sha256:dac150b5…` and `tb-rating`
`sha256:a962eade…`, the same bytes jodi's image built, although the build's path remap is now
`/src=/soma`: the release profile strips, so no path survives into either component, and the
signatures devops already holds stay valid. The generator's output is now formatted by
`orion-server fmt`, because it is committed beside files held to the house style.

**Verified.** `check-defs.sh` clean at 45 channels, 45 workflows and 10 connectors; 30 rating and 35
pairing tests pass (jodi's docs said 27 pairing); `check-sql.sh` prepares 91 statements;
`verify/run.sh` reports the same scenario output as HEAD apart from the three replaced statements;
the image builds; and on a fresh volume the loader applied one `pkg:soma` with both plugins signed,
the four clocks ran over `soma-db`, `smoke.sh` passed 48/48 as an admin, and `devops/scripts/dev/submission-storm.py`
decided 30 of 30 submissions -- 29 promoted and rated, one rejected `UNPLAYABLE` during a models
read-key outage the fresh volume caused (devops' Status has it). What is not exercised: the
`pkg:jodi` → `pkg:soma` hand-over on a node that still runs the old package.

**16 September 2026 (later) — the `Bearer ` space is a check now, and the token route's limit is a
fleet ceiling.** `scripts/check-auth-scheme.py` runs in `check-defs.sh` and refuses an
`auth.source.scheme` that does not end in a space. It is there because the fix was lost a **second**
time — the first to being typed without it, the second to a `git checkout` of a working-tree change
that was not committed — and a live fleet spent eleven minutes minting tokens and claiming nothing.
Every offline gate passes either way, and so do the four smoke checks that assert `401`; the only
thing that caught it is `smoke.sh`'s single **round trip**, which exists because of the first time.

**`POST /v1/runner/token` is rate limited on the caller's address and cannot be limited on anything
else** — it is the route that establishes the principal — so its limit is a ceiling on machines per
**source address**, and several machines in one office are one address. A replica mints a token per
call, not per ten minutes: every cron run is a fresh execution carrying no state. Measured, 214
exchanges against 214 authenticated calls in 120 seconds, 0.89/s per idle runner. At the 5 rps it
shipped with, the sixth machine behind a NAT was refused — **silently**, because the caller's call is
soft and the run ends at `noauth` with outcome `no_token`. It now carries `runner_token_rate`, equal
to `runner_rate`. The real repair is not minting a ten-minute credential for one call.

**16 September 2026 — the runner routes stop running as the database owner.** N17, and it is the
repair for the one boundary the gate weakened by shipping inside this package. The eight
machine-facing routes now run as **`runner_gate`**, a third role that is `kalam`'s grant plus exactly
what the routes added — `played_by`, `live_runners`, the `runners` upsert and the season columns the
execution contract reads. Not a widened `kalam`: that role is still held by an in-cluster replica,
and widening it is what the migration forbids. **The five admin routes stay on `soma-db`**, because
`runner_keys` is Soma's auth surface, the same as sessions.

Measured, not asserted: the role can claim, finish and read a season's rules, and **cannot** write a
rating, read `users`, enumerate runner keys, promote a version, change a season or touch `clocks`.

**It needed a second view.** The token exchange joins `runner_keys` to `users` to check a key belongs
to a live admin, and the role must read neither — so `live_runner_keys` does the join the way
`live_runners` already does, owned by the schema owner and running with its privileges. Three
statements moved onto it.

**The finish gained the three misconfiguration gates** (`devops/docs/decisions.md` §4b), and one of
them is not what the proposal said. "Ranks a permutation of `0..seat_count-1`" is wrong about this engine: Ants ranks **from 1**
and **allows ties**, so a draw is `{1,1}` and is the commonest two-seat result. The bound that is
actually true is `1 <= rank <= 2*seat_count`. Checked against `match_seats` before shipping, and the
harness now carries a draw among its fixtures so it cannot regress.

**16 September 2026 — the gate is what a replica actually plays through.** A Kalam replica in
`api` mode claimed, started, renewed, presigned, uploaded and finished two matches entirely over
`/v1/runner/*`, and both re-played **IDENTICAL** locally. Two changes here made that work:

- **The claim's idle answer is `200 {"idle": true}`, not `204`.** `http_call` parses every response
  as JSON, because every other answer from this route is JSON — so the *common* case failed the
  parse, once per poll per lane, and a healthy fleet read as a broken one. Fourteen bytes was the
  whole saving. `constants.no_content` stays for `soma-admin-check`, where nginx is the only client
  and a 204 really is the answer.
- **`soma-runner-blobs` signs for `RUNNER_BLOB_ENDPOINT`**, the address a *runner* reaches the
  object store on, which is not `R2_ENDPOINT` — that one is what a browser fetches a replay from.
  SigV4 signs the host.

**16 September 2026 (latest) — a season owns the terms a model competes under.** `turn_ms`,
`max_turns` and `refusal_ceiling` become `season_rules.execution`, read
`coalesce(season rule, games.manifest -> 'limits', [vars])` from **the row's own season** inside the
claim's read-back — the shape Jodi already uses for `adapter_ops_max`. A speed season is
`{"execution": {"enabled": true, "turn_ms": 250}}` and nothing else.

**Why these were the last `[vars]` left is a grant.** The `kalam` role has no privilege on
`seasons`, so the process that needed them could not read the table they belong in — which is also
why `matches.strike_ceiling` is pinned per row. The gate assembles the claim at the centre, where
`matches → seasons` is one join it already has, so a value no longer has to be copied onto a match
row to reach the process that plays it. Nothing is pinned for this: `rules` is immutable once
submissions open, so a queued match keeps the terms it was queued under.

**`renew_every_n_turns` is now derived, not sent** — the deployment's target clamped by
`floor(lease_seconds × 1000 / (3 × turn_ms))`. Without it a season setting `turn_ms = 5000` leaves
the lease expiring before the renew fires on *every* match, reading as a wedged runner; a range
check cannot close that, because the safe ceiling depends on a number in another file. And
`GET /v1/games/{slug}` serves the **effective** limits, or the site states a turn budget the ladder
does not play by.

`enabled` is honoured rather than ignored, unlike the other value-supplying blocks: a rule that
applies when its author turned it off is what `season_rules_ok()` was written to prevent.

**16 September 2026 (later) — the gate answers.** The runner routes needed `RUNNER_TOKEN_SECRET` and
seven `[vars]` that only `devops` could supply; those landed, and exercising the path end to end found
**a one-character bug that made every runner call impossible**. `runner_auth` declared
`"scheme": "Bearer"`, and Orion strips the configured scheme as a *literal prefix*, so the token
arrived with a leading space and failed to parse. Orion's own default is `"Bearer "` **with the
trailing space**; a hand-written config is how it is lost.

What makes it worth writing down is that **nothing could see it**. Every offline gate passed —
`"Bearer"` is a valid string. And the four smoke checks beside it asserted `401`, which is exactly
what the bug produces, so they stayed green while no token could ever be accepted. `smoke.sh` now
mints a key, exchanges it and claims with the token: **an auth route needs one round trip that gets a
2xx**, because a refusal only proves the channel loaded. 48/48, and the claim returns its contract.

**16 September 2026 — Soma serves the runner gate; a replica gives up its database credential.**
Thirteen routes and one cron channel: `/v1/runner/*` for machines and `/v1/runner-keys` +
`/v1/runners` for the admins who start them. The eight match statements move here from
`kalam/scripts/gen-kalam.py` unchanged, with one route in front of each, so a Kalam replica can run
on hardware outside the deployment holding nothing but an API key.

**Three predicates were added to the SQL and nothing else was touched.** A `live_runners` EXISTS in
every statement, so revoking a key or demoting its owner ends the next call; an in-flight ceiling in
the claim, so a wedged machine cannot sit on rows until their leases lapse; and `matches.played_by`,
written at claim, because without it "which machine is wedged" has no answer. The claim now returns
the **execution contract** — `turn_ms`, `max_turns`, `lease_seconds` and the rest — from the one
place that owns them, deleting the class of failure `devops/scripts/check/configs.sh` exists to
catch and cannot catch on a machine it cannot read.

**Two shapes are new rather than moved.** `finish` reads the row back under the same token, so a
duplicate delivery is a `200 {applied: false}` and only a genuinely lost claim is a 409 — over a WAN
both were `rows_affected = 0`, and a runner that finished correctly and lost the response would have
reported a fault. And the reap left the claim path for `soma-runner-reap`, this package's first cron
channel, singular because Soma's Orion runs in cluster mode: as every caller's first task it was
0.8N reaps a second scanning an index proportional to N.

**Runner keys are hashed, not stored.** `runner_keys` holds sha256 of the key and a display prefix,
and `POST /v1/runner-keys` is the only response that ever carries the key material — so reading the
table does not let anyone start a runner. The design asked for a readable key; this is the variant
it named as better hygiene, and it costs one column.

**One boundary is weaker and it is deliberate.** These routes run over `soma-db`, the owner, rather
than the column-limited `kalam` role, because they are in this package rather than a second one. See
**What must stay true**; the trade and the way back are written on the grant block in the migration.

`docs/schema.md` §3.8a, §4 and §4a were rewritten with it — §4 still described the pre-R7 wave claim,
as did `scripts/verify/statements.sql`, which had been proving races against a statement that does
not ship. `run.sh` now asserts the copies match. **Still to land, in devops:**
`RUNNER_TOKEN_SECRET` on the soma container and seven `[vars]` in `soma.toml.tmpl`; until then the
runner routes load and answer 500.

**16 September 2026 — GitHub leaves the submission path; an entry is a name.** No repository per
entry and no release per version. `models` loses `repo`, `owner_github_id`, `owner_login`,
`models_repo_canonical`, `models_repo_uniq` and `models_owner_game_repo_uniq`; `model_versions`
loses `release_tag` and `commit_sha` with `model_versions_release_uniq`; `repo_path()`,
`season_admits_repo()` and the `repo` block of the season rules are deleted, and with the last of
them **every rules block now defaults off** — `repo` was the lone default-true one, guarding a field
that limited nothing. Every ceiling on a competitor was already a season rule and none of them
mentioned a repository.

`soma-models-create` loses both `github-api` tasks, the `503 repo_unverified` terminal and the
`409 repo_private` one: **creating an entry no longer depends on GitHub being up**, and this package
now reaches no host outside the deployment except at sign-in. `connectors/github-api.json` stays for
exactly that one user, `soma-auth-github`.

**Two route changes.** `/v1/games/{game}/models/{owner}/{repo}` becomes **`/v1/models/{id}`** for
GET and PATCH — the shape `/v1/matches/{id}` and `/v1/versions/{id}` already use — and
`POST /v1/submissions` drops `release_tag`, taking the entry as an id and letting `version` be the
counter the insert assigns. `models_owner_game_name_uniq` is the entry's only key and is per owner,
so two competitors may hold one name; `name` therefore keeps its free-text CHECK, because it never
has to survive a URL. The seeded baselines lose the partial-index carve-out that let three of them
share one repository.

**A bug fixed on the way.** The submission response has always promised "ask again … to get fresh
[upload URLs]", and `refused` answered `409 version_in_flight` instead — so a competitor who lost
their 30-minute presigns had a version they could neither upload to nor replace. Re-POSTing the same
two hashes now falls through to the read-back and re-signs.

Breaking changes to `POST /v1/models`, `POST /v1/submissions` and both model routes, which is free
pre-release. **`web/` has not followed yet** and its model pages, entry creation and submit form are
broken against this API until it does.

**15 September 2026 — the set says each thing once, and the loader compiles it.** `shared/soma.json`
holds the constants and two fragments the 26 channels and 26 workflows now reference: the JWT-from-
cookie `auth` block that was copied 15 times, the four rate-limit shapes, the two cache policies,
the `{status, body_path}` response objects, and a `refuse` fragment that replaced **39 hand-written
terminal refusal tasks** across 16 workflows plus a `deny-revoked` one that replaced the 13 copies
of the session-revocation guard. `orion-server clippy` went from 18 findings to 0 and `fmt --check`
from 23 failing files to none. The refactor is proved rather than asserted: compiling the new set
and diffing every entity against the old one leaves exactly two intended differences — the
split-body refusals folded into one object literal, and a description added to the session guard.

`scripts/load-package.sh` is now `orion-server compile` + `orion-server package apply`, because a
set carrying `$from` and `use` is refused by the admin API until it is compiled. It stages a copy
with this deployment's connector settings written in, retires only what the artifact does not carry,
and applies one artifact whose version names its content. Apply is idempotent, atomic on failure and
never takes a route down between a DELETE and its POST, which the old loop could not manage. New:
`scripts/check-defs.sh` — lint + clippy + fmt with `--deny-warnings`, no stack needed. 33/33 smoke
against the live stack.

Two pre-existing bugs in `scripts/smoke.sh` fixed on the way: it asked for `models.status`, a column
that does not exist, so `$MODEL` was empty and two checks tested nothing; and it asserted
`/v1/models/{id}`, a route replaced by `/v1/games/{game}/models/{owner}/{repo}`.

**15 September 2026 — the anonymous reads are cached.** A `soma-cache` connector (Redis, logical
db 1, so a cache key cannot collide with the cluster state on db 0) and `config.cache` on the nine
caller-invariant read channels: 10 s on the leaderboard, the match lists and the by-id reads —
count folds every 10 s, so that is at most one fold of staleness — 60 s on the season list, 300 s on
the two game routes, which change only on a deploy. Measured on the running stack: the leaderboard
goes 24.9 ms cold to 1.5 ms warm. No `cache_key_fields` and no `key_logic`, because the default key
already feeds the method, the path params and the query before the payload; what it does not feed is
the caller, which is exactly why no authenticated channel may have one. Two things worth knowing
before adding a tenth: the connector's `operations` gates reach the response cache even though no
workflow calls it — `write: false` quarantines every channel that names it — and its `url` may not
be an `env://` reference, so `load-package.sh` substitutes `SOMA_CACHE_REDIS_URL` at load.

**15 September 2026 — the public routes are metered.** Twenty-five of twenty-six channels declare
`rate_limit`, the address-keyed guard Orion applies before `check_auth`: 30/60 on the ten anonymous
reads, 5/10 on the sign-in leg, 20/40 on everything authenticated — strictly looser than every
`principal_rate_limit` on the same channel, so a single competitor still meets their own quota first
and the address limit only catches many callers behind one address. Before this the eleven
unauthenticated routes had no limit of any kind, on either side of nginx, because
`principal_rate_limit` cannot see a caller who has not signed in. `soma-admin-check` keeps none, and
its workflow description says why. **It depends on a DevOps half**: Orion believes a forwarded
address only behind a peer in `[rate_limit] trusted_proxies`, and the peer here is nginx. Driven
against the running stack — 150 requests from one address answered 90/60 split 200/429, while a
second address was untouched.

**14 September 2026 — a submission carries a manifest, and Soma hands back where to put it.**
`model_versions` stores `manifest` / `manifest_hash` / `orion_version` / `probe_dims` where it
stored `adapter` / `adapter_hash` / `evaluator_digest`, and `artifact_key` is a GENERATED column —
`models/<version_id>/model.onnx` — so the three readers of a version's bytes cannot disagree about
where they are. `POST /v1/submissions` answers 201 with two **presigned PUT URLs**: nothing on the
platform fetches a competitor's bytes over the internet any more, which is what let the admission
service and its allowlist be deleted. The weight class is `artifact_bytes + len(manifest)` and the
class table doubled to match a raw metric where the old one was compressed.
devops/docs/decisions.md, the R-series.

**11 September 2026 — a leaderboard row carries its last dozen ratings.** `soma-leaderboard` adds
`history` beside `trend`: the last twelve conservative ratings on the ladder, oldest first, the seed
at promotion included, rounded to two places — one correlated subquery over `rating_events` per
row, the same shape `trend` already ran. Enough for the site's sparkline; a version's full chain
stays off the public routes. `check-sql.sh` passes all 47 statements, and the reloaded package
answers the field on the running stack.

**11 September 2026 — `pairing.trial_opponents` is gone.** Nothing read it, and its `field` and
`both` values promised trials against something other than a baseline, which is the one thing a
baseline is for (decision 28). `scripts/verify` carries Jodi's demand view without its baseline
branch: a baseline is paced like every version, and the walk shows it wanting its own placement and
its owner in the queue-share map.

**11 September 2026 — the handle is a label, not an identity.** `users.handle` is a cache of a
mutable remote value refreshed only at sign-in, and three sign-ins were dying on it: a new account
taking a login freed by a rename, an existing account renaming into a login a stale row still held,
and a real GitHub account whose login happened to equal a seeded baseline handle — `baseline-nano-bc`
was a perfectly mintable login, so that person could never sign in at all. Uniqueness moves to
`lower(handle)`, which is the namespace every reader already compared in: a case-sensitive index
with case-insensitive readers is how `Alice` and `alice` became two rows that answered to one login
and both passed `repo_owned()` for the same repository. The baselines move to `baseline.<artifact>`
and a released login is parked under `released.<github_id>` — a login is `[A-Za-z0-9-]`, so a dot is
a namespace GitHub cannot mint against us. Sign-in now takes a login off the row that provably no
longer holds it before claiming it, in a statement of its own: folded into the upsert as a
data-modifying CTE the two would share a command id, and the release would not be reliably visible
to the insert's uniqueness check. `scripts/verify/scenario.sql` walks all four cases.

**11 September 2026 — ownership is an account id, asked of GitHub once.** That was the reason the
handle mattered. `POST /v1/games/{game}/models` now calls `GET /repos/{owner}/{name}` before it
writes anything and compares `owner.id` with the caller's `users.github_id`, recording both the id
and the login on `models`. `repo_owned()` is gone; `season_admits_repo()` takes GitHub's answer.
Renaming yourself on GitHub no longer costs you your models, and no longer hands anyone the ones you
left behind. Two refusals came with it, both of which used to be discovered at the first submission:
`repo_private`, because release assets are fetched without a token, and `repo_unverified` — a 503
when GitHub does not answer, which **never** falls back to comparing logins, because that fallback
is the hole and anyone could reach it by exhausting the rate limit.

The token is optional in code and required in practice. Unauthenticated GitHub is 60 requests an
hour *per IP*, and the IP is this server's, so it is 60 model creations an hour for every competitor
together; `github_token` is a `[vars]` value defaulting to empty and `devops/scripts/check/configs.sh`
says out loud when it is unset. Two sibling tasks with opposite conditions make the header optional,
because a header cannot be conditionally omitted and an empty `Bearer` would 401 sign-in as well.

With that, decision 51's uniqueness claim is finally true, and `models_repo_uniq` states it:
`UNIQUE (game_id, lower(repo)) WHERE owner_github_id IS NOT NULL`. One entry per repository,
platform-wide. The partial predicate is the one exception and it names itself — a row without an
`owner_github_id` never went through the route, which is the three seeded baselines sharing one
repository.

**And an allowance to everyone came out.** `repo.allow_orgs` had no membership check, and season 1
shipped `allow_orgs: ["Tiny-Brains"]`, so any signed-in competitor could create an entry on
`Tiny-Brains/ants-baselines` and submit the platform's own baseline release as their own model. The
seeded line is gone — the baselines are INSERTed and never reach the route, so it bought nothing —
`season_admits_repo` honours the key only for accounts the season also lists as participants, and
`season_rules_ok` refuses it without them.

**10 September 2026 — an entry and a version are two tables, and a season declares its own rules.**
`models` is now the entry — a competitor's named lineage, keyed by the GitHub repository it
publishes from — and `model_versions` is one submission of it. A competitor may hold as many models
as the season allows; version numbers restart per model; one version of a model is in admission at
a time. Everything a rating, a seat or a match points at is a version (`ratings.version_id`,
`match_seats.version_id`, `matches.trial_version_id`), and the API keys that name them on the wire
were deliberately left alone so the two Rust plugins and the replay envelope needed no change.

`seasons.rules` became the whole description of a contest: ten blocks validated by
`season_rules_ok()` against a `season_rule_spec()` VALUES table, every one optional and every one
read `coalesce(rule, <the deploy's value>)`, so a season that declares nothing behaves exactly as
before. Three new routes carry it — `POST`/`GET`/`PATCH` on `/v1/games/{game}/models` — and
`GET /v1/versions/{id}` is the old `GET /v1/models/{id}` under its true name.

**Two bugs came out with it.** Count's predecessor read was scoped by owner with no season term, so
it would have raised "more than one row" the first time a second season opened and taken the ladder
down with it; `scripts/verify/scenario.sql` now asserts the fix. And `season_json()` returned
`rules` verbatim to six public routes, which published the participant list of a private cohort to
anyone who asked for the game.

**10 September 2026 — the package ships as an image.** Nothing here is generated, so nothing left
git; this is the other half of the same change. `Dockerfile` carries `channels/`, `workflows/`,
`connectors/`, `migrations/` and `load-package.sh`, and devops copies them into a volume it mounts
where it used to mount this checkout. `../soma` was the last bind mount on the platform, and its two
migration files were the last thing Postgres read by path.

The migrations travel under **their own names**. DevOps slots them into Postgres's init directory as
`20-soma-schema.sql` and `25-soma-sessions.sql`, between its own `10-` and `30-` scripts; that
ordering is its decision, not this repository's, so the renaming happens there.

**Per-seat cost on `match_seats`, 10 September 2026.** Three columns Kalam writes at finish —
`infer_us_total`, `infer_us_max`, `infer_turns` — recording what each seat's model cost rather than
only what it scored. Deliberately outside `match_seats_result_whole`: timing drives no rating and no
rank, so binding it to the result would halt a wave mid-deploy for a row finished by a Kalam that
predates the columns, and force an unmeasured seat to carry a fake `0`. Verified against the running
stack: a match played by the fleet wrote 78,360 µs over 150 turns for one seat and 77,973 for the
other, matching its replay envelope exactly.

**Decision 46, 10 September 2026 — no compute cap.** `models.flops_estimate` became
`models.infer_us` (microseconds, measured at admission, reported and never a gate);
`soma-games-get` no longer joins the cartridge's per-class cap onto `weight_classes`, so a class is
its byte limit and nothing else; `soma-models-get` and the `soma-seasons-create` baseline carry
follow. `0001_init.sql` was rewritten in place, as a pre-release schema is. All 38 statements prepare.

**10 September 2026.** The package implements twenty-three routes, OAuth sessions, season
administration, submission recording, replay signing, and the shared schema. Orion 1.8.1 lint
passes clean at 22 channels and 22 workflows; `check-sql.sh` prepares all 38 shipped statements;
`smoke.sh` passes every check against the local stack (32 with a competitor's handle, 33 with an
admin's, which reaches one more); `verify/run.sh` walks the schema, both fence races, the seed and
the Kalam role.

Two things are known and open. The OAuth callback cannot land its three failure states on a page,
because `oauth2_login` answers a fixed 401 and never runs the workflow: the web proxy intercepts
that status and redirects, so the page is reached but cannot say which failure it was, and the fix
is a `failure_redirect` on the channel, which is Orion's to grow. And `orion-server clippy` reports
fourteen duplications this package cannot yet remove: the JWT auth block written out in twelve
channels, and the response and session-guard steps repeated across the workflows. Orion 1.7 has the
answer -- a shared `definitions/` document of `constants`, `errors` and `fragments`, referenced with
`$from` and `use` -- but those resolve at `orion-server compile`, and the admin API this package is
installed through takes one document at a time and resolves nothing. Adopting them means the
DevOps loader image carrying the orion-server binary and `load-package.sh` compiling before it
POSTs, which is a deployment change for all three packages rather than a Soma edit.

API tokens for SDK/CLI use remain unimplemented, and an authenticated end-to-end sign-in still
needs a configured OAuth App rather than a minted cookie.

### Before the merge (was jodi)

The Status entries of the `jodi` repository, as written there, oldest last. Paths in them are jodi's:
`scripts/gen-jodi.py` is `scripts/gen-clocks.py`, `docs/design.md` is `docs/clocks.md`, and
`connectors/jodi-*.json` are the renamed connectors above.

**16 September 2026 — Jodi reaches no host outside the deployment.** The `commit` task is deleted
with the GitHub release it read: `GET /repos/{repo}/commits/{tag}` was best effort, so a 404 or a
rate limit already left `commit_sha` null and the walk carried on — it gated nothing and audited
nothing. `connectors/jodi-github.json` goes with it (that task was its only user), and so do
`commit_sha` from both verdict statements and `release_base`, **a `[vars]` value read by no task at
all**. The admit walk is 26 tasks, not 27.

The four connectors left are `jodi-db`, `jodi-orion`, `jodi-models` and `jodi-blobs-get`, and every
one of them addresses something inside the deployment. That makes `admission.md` §2's fourth
consequence a plain statement rather than a qualified one.

Schema side, in `soma/migrations/0001_init.sql`: `model_versions` loses `release_tag` and
`commit_sha`, `models` loses `repo` and the two GitHub ownership columns, and the batch document
stops carrying `repo`/`release_tag` — which leaves its join to `models` dead, so that goes too.

**15 September 2026 — nothing could be admitted, and then one submission could stop everyone.** The
first real submissions ever to reach this clock found three defects, each behind the last. None had
a symptom worth the name: the walk logged a clean run, the node reported the model admitted, and
the row sat in `testing` -- which reads as slow, not as broken.

1. **`verify` was gated on a value nothing writes.** `STILL_GOOD` read `temp_data.resident`, which
   the old loader's reply set (`load.models.0.state`); the commit that replaced the loader with
   Orion's `models` entity deleted every task that wrote it and left the read. `verify` is the only
   task that reads `STILL_GOOD`, so its condition was simply never true. It now reads
   `temp_data.head`, which is the residency fact the rebuilt walk actually has and the same one
   `ARTIFACT_MISSING` is decided on.
2. **`infer_us` was bound as an integer and measured as a fraction.** The probe reports
   `1000 * inference_ms`, so what reached `($6)::bigint` was a JSON number with a decimal part, and
   the driver refuses that before Postgres sees it. `verify` carries no `continue_on_error`, so the
   failure killed the **whole run**: the claim was never released, `reject` and `giveback` never
   ran, and the next sweep re-walked a model that was already registered — 409 on `register`, 404
   on `activate` (*no draft version*), `PROBE_UNREACHABLE` for ever. The cast is now
   `($6)::float8::bigint`: the column is whole microseconds and the measurement is not.

**What found them, and what did not.** `check-defs.sh` passes on both — an undefined `temp_data`
path is a value that is null, not a reference that dangles, and no lint can know a placeholder's
type. `check-sql.sh` passes on both, because the statement is valid SQL either way. What found them
was `devops/scripts/dev/submission-storm.py`, which submits as tens of competitors do and reads the
verdicts back: the first defect showed as thirty rows stuck in `testing`, and the second was named
in one line by the trace the first one hid.

3. **One submission could stop admission for everyone**, and it is the same `None` trap as (2)'s
   neighbours. `item` clears every per-item slot with `False` because dataflow-rs SKIPS a mapping
   whose logic evaluates to null — and `temp_data.retry`'s own chain ended in `None`, so in the
   normal case it wrote nothing and kept the *previous* item's value. Every task after it is gated
   on `{"!": retry}`, so one submission whose probe timed out took the rest of its batch down with
   it: skipped wholesale, released untouched. `claim` orders by `created_at` and `giveback` hands
   the attempt BACK, so the poisoned row was re-claimed first on every tick, never reached
   `admit_attempts_max`, and never expired. Found by the second storm run, where **24 submissions
   sat at `admit_attempts` 0 behind one**; after the fix the same 24 cleared in under three minutes.

**The re-walk is still not idempotent, and it is filed rather than fixed.** §5 calls the walk
idempotent, and it is not: `register` 409s and `activate` 404s (*no draft version*) on a model this
node has already archived, so a submission that needs a second attempt can never get one — and
because `giveback` returns the attempt, it is never expired either. It is not hypothetical: under
the second storm one submission in thirty hit it, when its probe exceeded `admit_deadline_ms`
(5 000 ms) while the fleet was playing. Two things to decide together: whether a re-walk should
re-register rather than 409, and whether admission's probe deadline can hold while the same node's
CPU is serving matches.

**15 September 2026 — the probe never ran, and `clippy` is why we know.** Two bugs in `tb-probe`,
both from the rebuild commit three days earlier, both silent. The admit walk called it with `body`
where `channel_call`'s payload field is `data`, and an unknown input key is *ignored*, not refused.
And `tb-probe-run` read `data.observations` with no `parse_json`, while `channel_call` delivers its
argument as the child's **payload** — so even the right key would not have been visible. Together:
`init` failed on `length` of nothing, `continue_on_error` swallowed the 500, every `ADAPTER_*` arm
of the reason ladder is guarded on `!!probe` so none fired, and the *retry* ladder set
`PROBE_UNREACHABLE` — every submission released, retried, and finally rejected `TIMED_OUT`. **No
model could be admitted.** `orion-server clippy` names the first in one line as
`correctness.unknown_input_key`; nothing else this repo runs did. Verified fixed on the live stack:
the probe now walks all 10 of the game's reference observations (`checked: 10`) where it previously
crashed on task one.

Also: `shared/jodi.json` holds the clock tracing block the five channels copied, and the generator
gained `group_runs()`, which collapses each run of consecutive tasks sharing one condition into a
task group. `clippy` went from 1 error + 11 warnings to 0/0. `scripts/load-package.sh` is now
`orion-server compile` + `package apply`, carrying both wasm plugins and their signatures in one
artifact; `scripts/check-defs.sh` is the no-stack gate. Compiling the regenerated set and diffing
every entity against the old one shows **zero** differences, so the grouping changed nothing.

**14 September 2026 — admission is Orion's, and the loader is gone.** The admit walk registers a
submission on this node by reference and digest, runs admission synchronously (`/admit?wait=true`),
activates it long enough to play it over the game's reference observations through the new
`tb-probe` channel, applies the platform's policy to what the node reported, and archives it again.
Nothing here fetches a competitor's bytes over the internet any more: they arrive in the models
bucket through a presigned PUT Soma mints, and the node's storage connector is what reads them. The
verdict now records `manifest`, `manifest_hash`, `orion_version` and `probe_dims` where it recorded
the adapter, its hash and an evaluator digest, and the weight class is
`artifact_bytes + len(manifest)`. devops/docs/decisions.md, the R-series.

**11 September 2026 — a baseline is an ordinary version with a tag.** The demand view no longer
gives a baseline a state of its own: it is paced by placement, unsettled and settled like every
version, so a fresh stack plays its baselines' placement against each other and then idles. Its
owner is held to `pairing.queue_share_max` like anyone's, and a season closes by settling only once
its baselines have settled too. The one thing a baseline still does alone is sit opposite every
trial: `P_TRIALS` is the only statement left that reads `users.role`, and the demand document
carries no role at all (decision 28).

The plugins' comments changed and their bytes did not: the image builds `tb-pairing`
`sha256:dac150b5…` both before and after this change, and `tb-rating` `sha256:a962eade…`. The
`f3dd85e9…` recorded below predates the owner-awareness change, which is what moved it.

**11 September 2026 — two bugs a clean volume found, both from the season-rules change below.**
`plugin.toml` still declared `cross_class_fraction` required after pair stopped passing it -- the
season's value moved into `demand.limits` -- so Orion 1.7 refused the pair workflow at create and
Jodi could not load on a fresh volume at all. It is optional now, which is what `lib.rs` already
treated it as. And count's `priors` statement had grown the season-rule fallbacks `$2..$4` without
its task passing them, so every fold failed validation and nothing was ever rated; the task passes
the three `ts_*` vars, and the rating reads the row's season-effective values instead of `[vars]`,
so a season's rating rule is honoured too. `check-sql.sh` caught neither: it prepares each statement
but never compares its placeholders with the params its task passes -- a check that, run over all 77
statements in the three packages, finds exactly this one.

**10 September 2026 — the clocks run the version life cycle over an entry that is a row of its
own.** Every statement that meant "the same competitor's other version" now means "the same
*model's* other version": promotion supersedes within one lineage, withdraw names the right
successor, and count's predecessor read is provably single-row. Jodi lost `UPDATE` on `models`
entirely — an entry's name, its repository and its retirement are the competitor's and Soma's, a
boundary that could not be drawn while the entry and the version were one row.

The season's rules reach the clocks as `coalesce(rule, <the [vars] value>)`, so a season that
declares nothing paces exactly as the deploy does. Admission carries each item's own season's graph
rules **per item** rather than reading them from `metadata.vars`, which is strictly safer: a root
var is one value for a whole run. Pair stamps `matches.strike_ceiling`, and the pairing plugin
gained owner awareness — no match seats two versions of one competitor unless a season says
otherwise, enforced in `P_INSERT` as well as in the plugin, because that half is correctness.

**10 September 2026 — the package ships as an image, and nothing generated is committed.**
`channels/`, `workflows/`, both components and both `plugin.json` files are gitignored; they are
built by `Dockerfile` and carried in the artifact image under `/artifacts/`. DevOps copies that into
a volume and mounts it where it used to mount this checkout, so the loader container — which has
curl and jq and no toolchain — no longer needs this repository beside it. `connectors/` is the
authored part and is copied through.

The image regenerates the declarations and then runs `gen-jodi.py --check`, so a hand-edited
workflow is a failed build. It builds the components under a pinned toolchain with
`--remap-path-prefix`, so a plugin digest is a function of the source rather than of the machine:
`docker build --no-cache` lands on `tb-pairing` `sha256:f3dd85e9…` and `tb-rating`
`sha256:a962eade…` every time. All eight generated declarations are byte-identical to the ones that
were committed.

**Signatures moved out of the package.** A signature belongs to whoever holds the trust key, and a
package that ships as an immutable image several deployments can share cannot carry one.
`load-package.sh` now reads `PLUGIN_SIG_DIR`, falling back to beside the component when it is unset;
devops mints signatures into its own `keys/signatures/` and mounts that. That also ends one
repository writing into another's working tree.

**10 September 2026 — the plugin workspace is edition 2024.** `cargo fix --edition` needed no source
changes; clippy took two `collapsible_if` sites into let-chains (`tb-pairing/src/choose.rs`,
`tb-rating/src/lib.rs`), and `rustfmt.toml` was added — the same `max_width = 100` /
`use_small_heuristics = "Max"` ants uses — so `cargo fmt` keeps the style the workspace is
written in rather than reformatting every file to rustfmt's defaults.

**Both components were rebuilt and their digests moved**, which is what a plugin rebuild always
means: `tb-pairing` is now `sha256:961948da…` and `tb-rating` `sha256:350e0212…`, and
`devops/scripts/setup/sign-plugins.sh` has to run again or the node comes up `degraded` with its
channels quarantined. No arithmetic changed — 57 host tests pass unchanged, and these two plugins
are the only arithmetic that writes a ladder and the only thing that decides who plays whom.

**Decision 46, 10 September 2026 — no compute cap.** The admit walk's `cap` task became `judge`: no
`flop_caps` lookup, no `FLOPS_OVER_CAP`, and no `MANIFEST_INCOMPLETE` for a missing cap. `A_VERIFY`
writes `models.infer_us` from `/validate`'s measured `infer_us_max` where it wrote `flops_estimate`
from an estimate — recorded for the competitor, gating nothing. Regenerated and `check-sql.sh` passes.

**10 September 2026.** All four clocks and both plugins are implemented; the host suites pass
30 rating and 27 pairing tests, `check-sql.sh` passes, and Orion 1.8.1 package lint passes. The
weight classes are read from the season rather than written into the admit workflow, and
`gen-jodi.py --check` now guards the generated workflows against hand edits. Package loading, SQL
behavior, and the full admission-to-promotion walk require the DevOps stack and are not established
by those unit tests. An adapter revalidation sweep, remaining admission fault exercises, and tuning
against a competitive roster remain open.

## More

- Local references: [migrations](migrations/), [channel contracts](channels/), and [workflow response mappings](workflows/).
- Local references: the [clock generator](scripts/gen-clocks.py) and the plugin manifests linked above.
- Design docs: [`docs/schema.md`](docs/schema.md) — the match table, its fences, and every statement the packages run against it; [`docs/clocks.md`](docs/clocks.md) — the clocks; [`docs/admission.md`](docs/admission.md); [`docs/rating-and-seasons.md`](docs/rating-and-seasons.md); [`docs/config.md`](docs/config.md) — every number, and what measures it.
- [The competitor guide](https://github.com/Tiny-Brains/web/tree/main/docs) — the reader-facing half: the rules, the model format, the manifest, submitting, ranking and seasons. The platform section is the high-level design for someone new to the codebase.
- Related repositories: [Web](https://github.com/Tiny-Brains/web), [Kalam](https://github.com/Tiny-Brains/kalam), [DevOps](https://github.com/Tiny-Brains/devops). [Jodi](https://github.com/Tiny-Brains/jodi) is history only.
- Apache-2.0: see [LICENSE](LICENSE).
