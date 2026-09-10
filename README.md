# soma

Soma is the public API and schema owner for TinyBrains. It ships an Orion 1.7.0 package of REST
channels, workflows, and connectors, plus the Postgres migrations shared by the platform.
It ships definitions and no server; [DevOps](https://github.com/Tiny-Brains/devops) chooses the
orion-server instances that host them.

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

**It does not**

- Admit, pair, count, promote, or withdraw versions; [Jodi](https://github.com/Tiny-Brains/jodi) runs those clocks.
- Play matches or upload replays; [Kalam](https://github.com/Tiny-Brains/kalam) executes matches.
- Run models; [Axon](https://github.com/Tiny-Brains/axon) evaluates adapters and ONNX graphs.
- Implement game rules; [Ants](https://github.com/Tiny-Brains/ants) is the reference cartridge.
- Define deployment addresses, credentials, or replica counts.

## Where it sits

```text
[Browser / API client] -- HTTP --> [Soma] -- SQL --> [platform Postgres]
                                     |   |
                                  OAuth  signed replay GET
                                     v   v
                                [GitHub] [object store]
```

| Direction | Party | Over | What moves |
|---|---|---|---|
| called by | Web and API clients | HTTP /v1 | Queries, submissions, and session actions |
| reads | Postgres | soma-db SQL | Games, versions, results, ratings, and seasons |
| writes | Postgres | soma-db SQL | Users, sessions, submission records, and season requests |
| calls | GitHub | github-api HTTPS | OAuth exchange and account identity |
| calls | Replay store | soma-blobs signing | Time-limited GET URLs; no replay upload |

Jodi and Kalam coordinate through this schema, not through API calls to Soma.
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
| GET | /v1/matches | Public | A season's matches with every seat; or one model's, or one owner's |
| GET | /v1/matches/{id} | Public | Match details, seats, the ladders it counted on, and a signed replay URL |
| GET | /v1/profiles/{username} | Public | A competitor's public page: their versions by game and season |
| GET | /v1/me | Session | Current user and any candidate in flight; 401 when unauthenticated |
| PATCH | /v1/me | Session | Edit the display name |
| GET | /v1/me/matches | Session | The caller's matches in every state, queued and cancelled included |
| GET | /v1/sessions | Session | The caller's live sessions |
| DELETE | /v1/sessions/{sid} | Session | Revoke one session; `others` revokes all but the current |
| DELETE | /v1/session | Session | Revoke the current session and clear the cookie |
| POST | /v1/submissions | Session | Record a release and declared asset hashes as a testing version |

Read routes are public unless they can return something private. The split is a property of the
channel, never of a parameter: `GET /v1/matches` omits queued, cancelled and trial rows for
everyone, and `GET /v1/me/matches` is a separate route rather than `?owner=me`, because a public
route that quietly returns more to some callers is the shape a privacy bug arrives in.

A submission must satisfy the open season's rules. Recording it does not imply acceptance:
Jodi performs admission and the trial before promotion. The callback is served by the sign-in
channel, so twenty-three routes are implemented by twenty-two channels.

The migrations are also an interface. Apply both [0001_init.sql](migrations/0001_init.sql) and
[0002_sessions.sql](migrations/0002_sessions.sql); the table below describes writer ownership.

| Table or view | Purpose | Writers |
|---|---|---|
| users | Competitor identity, display name, and role | Soma sign-in and PATCH /v1/me; administrative provisioning for roles |
| sessions | Revocable sessions, with the browser and when it was last used | Soma |
| live_sessions | Unexpired, unrevoked session view | None directly; derived from sessions and users |
| games | Cartridge registration, its `about` copy, and current engine | Deployment registration |
| seasons | Competition windows, rules, weight classes, and engine identity | Soma admin routes; Jodi closure; deployment engine updates |
| models | Submitted versions and admission state | Soma inserts testing rows; Jodi admits and changes roster status |
| matches | Queue, execution history, and count marker | Jodi inserts/counts/cancels; Kalam executes |
| match_seats | Version snapshots and per-seat results | Jodi inserts; Kalam records results |
| ratings | Per-version ladder state | Jodi count |
| rating_events | Auditable before/after rating updates | Jodi count |
| clocks | Run fences and roster epoch | Jodi; deployment bumps roster epoch on engine cutover |

Against the local DevOps instance, check the public route:

```sh
curl --fail --silent --show-error http://127.0.0.1:8080/v1/games
```

## Run it, test it

Soma needs Orion and a migrated database. The [DevOps setup](https://github.com/Tiny-Brains/devops#run-it-test-it)
provides both, plus replay storage and the browser proxy. Run package commands from this repo root.

- Orion server 1.7.0 and Postgres 16 for the supported local stack.
- curl plus jq or Python 3 for loading; Python 3 and Docker for the SQL check.
- An OAuth App for sign-in; its callback must point at the browser-facing origin.

After provisioning the runtime settings below and pointing ORION_ADMIN at that instance, load:

```sh
./scripts/load-package.sh
```

Check the definitions and their SQL:

```sh
orion-server --version
orion-server lint . --deny-warnings   # references, schemas, and every declared env var
orion-server clippy .                 # advisory: duplication, dead conditions, unordered pages
orion-server fmt --check .            # the house style for definition JSON; drop --check to apply
./scripts/check-sql.sh
./scripts/smoke.sh
./scripts/verify/run.sh
```

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

Use the pinned Orion 1.7.0 toolchain for these checks. Older binaries do not understand this
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
| prior_mu, prior_sigma, settled_sigma | Orion vars for leaderboard priors and provisional status | Must match Jodi's rating policy |
| season_gap_days | Orion var for the minimum gap between seasons | Missing or incorrect policy changes season-opening eligibility |
| ORION_ADMIN, ORION_ADMIN_API_KEY | Load-script destination and optional secret bearer token | Defaults target local admin; protected APIs require the token |
| SOMA_ALLOW_PRIVATE_DB | Loader flag, 1 for a private database address | Orion blocks a private database connection |

Orion also needs its own state storage, separate from the platform schema; DevOps supplies
ORION_STATE_DB_URL and cluster configuration. The [instance template](https://github.com/Tiny-Brains/devops/blob/main/orion/soma.toml.tmpl)
is the configuration reference, including session, quota, and season policy.
The browser origin, registered OAuth callback, and proxy must agree. Replay URLs must likewise
resolve from the browser, not only from containers.

## Layout

```text
channels/                    HTTP paths, session auth, and quotas
workflows/                   request handling, inline SQL, and response mapping
connectors/soma-db.json       platform database connection
connectors/github-api.json    GitHub API connection
connectors/soma-blobs.json    replay GET signing; PUT disabled
migrations/0001_init.sql      platform tables, constraints, fences, grants, and the shared functions
migrations/0002_sessions.sql  sessions and live_sessions view
scripts/load-package.sh      replacement of objects tagged pkg:soma
scripts/check-sql.sh         preparation of every shipped query
scripts/smoke.sh             every route called, against a running stack
scripts/verify/              the schema walk: the scenario, both fence races, the seed and the grants
docs/schema.md               the schema's design, and every statement the three packages run
LICENSE                      repository licence
```

## What must stay true

- **Soma does not write competitive results or ratings.** This is a review boundary; its current database role is not restricted to API-only writes.
- **A shape many routes return is defined once, in the migration.** `season_json()` and `season_state()`, `model_ratings()`, `model_phase()`, `current_season()`, `match_seat_rows()` and the two `season_admits*()` rule predicates are where those shapes and judgements are built. Six routes return a season, three print "rank 6 of 47", three list a match's seats, and the submission rules are asked once by the insert that must not happen and once by the read that says why it did not. A second copy of any of them is a page that disagrees with another page, or a refusal whose reason denies it, with no way to notice.
- **A season owns its weight classes.** `seasons.weight_classes` is the only definition of what nano means; Jodi's admission reads the version's own season and the book points readers at it. The column is validated strictly ascending, because admission takes the first class a size fits and an out-of-order table makes a class silently unreachable. The trade is deliberate: a class result is comparable within its season, not across seasons.
- **A game introduces itself.** The provenance copy, the presets and the limits come from the cartridge manifest through `GET /v1/games/{game}`, so a second game is a registration and not a web deploy. The fold in the cartridge's own `build.sh` admits named keys only, refuses a non-string and requires https: this document is rendered in a browser.
- **Migrations define one schema for all packages.** A schema change must pass each consumer's SQL check before deployment.
- **Revocation remains effective before JWT expiry.** Session workflows consult live_sessions rather than trusting a signed token alone.
- **Kalam's role stays limited to execution.** The migration enumerates its writable columns and creates no embedded password.
- **Package reloads respect ownership tags.** load-package.sh replaces pkg:soma objects without sweeping Jodi's definitions.
- **Cookie behavior remains deployment configuration.** No route should hard-code a callback host or replace the declared Secure policy.

## Status

**Decision 46, 10 September 2026 — no compute cap.** `models.flops_estimate` became
`models.infer_us` (microseconds, measured at admission, reported and never a gate);
`soma-games-get` no longer joins the cartridge's per-class cap onto `weight_classes`, so a class is
its byte limit and nothing else; `soma-models-get` and the `soma-seasons-create` baseline carry
follow. `0001_init.sql` was rewritten in place, as a pre-release schema is. All 38 statements prepare.

**10 September 2026.** The package implements twenty-three routes, OAuth sessions, season
administration, submission recording, replay signing, and the shared schema. Orion 1.7.0 lint
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

## More

- Local references: [migrations](migrations/), [channel contracts](channels/), and [workflow response mappings](workflows/).
- Design docs: [`docs/schema.md`](docs/schema.md) — the match table, its fences, and every statement the three packages run against it.
- [The competitor guide](https://github.com/Tiny-Brains/docs) — the reader-facing half: the rules, the model format, the adapter dialect, submitting, ranking and seasons. The platform section is the high-level design for someone new to the codebase.
- Related repositories: [Web](https://github.com/Tiny-Brains/web), [Jodi](https://github.com/Tiny-Brains/jodi), [Kalam](https://github.com/Tiny-Brains/kalam), [Axon](https://github.com/Tiny-Brains/axon), [DevOps](https://github.com/Tiny-Brains/devops).
- Apache-2.0: see [LICENSE](LICENSE).
