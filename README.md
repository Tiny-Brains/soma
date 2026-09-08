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
| DELETE | /v1/session | Session | Revoke the session and clear the cookie |
| GET | /v1/me | Session | Current user; 401 when unauthenticated |
| GET | /v1/games | Public | Registered games |
| GET | /v1/games/{game}/leaderboard | Public | Standings; ladder, season, limit, and cursor query parameters |
| GET | /v1/games/{game}/seasons | Public | Game seasons |
| POST | /v1/games/{game}/seasons | Admin session | Create a season |
| POST | /v1/games/{game}/seasons/current/close | Admin session | Request closure of the live season |
| GET | /v1/models | Session | Caller's versions; optional game filter |
| GET | /v1/models/{id} | Public | Version status, ladders, and trial information |
| GET | /v1/matches | Public | Model history; model and limit parameters; finished and rated matches only |
| GET | /v1/matches/{id} | Public | Match details, seats, and signed replay URL |
| POST | /v1/submissions | Session | Record a release and declared asset hashes as a testing version |

A submission must satisfy the open season's rules. Recording it does not imply acceptance:
Jodi performs admission and the trial before promotion. The callback is served by the sign-in
channel, so fourteen routes are implemented by thirteen channels.

The migrations are also an interface. Apply both [0001_init.sql](migrations/0001_init.sql) and
[0002_sessions.sql](migrations/0002_sessions.sql); the table below describes writer ownership.

| Table or view | Purpose | Writers |
|---|---|---|
| users | Competitor identity and role | Soma sign-in; administrative provisioning for roles |
| sessions | Revocable sessions | Soma |
| live_sessions | Unexpired, unrevoked session view | None directly; derived from sessions and users |
| games | Cartridge registration and current engine | Deployment registration |
| seasons | Competition windows, rules, and engine identity | Soma admin routes; Jodi closure; deployment engine updates |
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
orion-server lint . --deny-warnings
./scripts/check-sql.sh
```

The SQL script prepares every shipped query against a scratch database created from both migrations.
It catches missing tables, columns, functions, and incompatible parameters, but does not execute the
REST workflows. There is no standalone HTTP behavior suite or meaningful unit-test count here.
It recreates soma_sqlcheck; set DB_CONTAINER and DB_USER to a development Postgres container.

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
migrations/0001_init.sql      platform tables, constraints, fences, and grants
migrations/0002_sessions.sql  sessions and live_sessions view
scripts/load-package.sh      replacement of objects tagged pkg:soma
scripts/check-sql.sh         preparation of every shipped query
LICENSE                      repository licence
```

## What must stay true

- **Soma does not write competitive results or ratings.** This is a review boundary; its current database role is not restricted to API-only writes.
- **Migrations define one schema for all packages.** A schema change must pass each consumer's SQL check before deployment.
- **Revocation remains effective before JWT expiry.** Session workflows consult live_sessions rather than trusting a signed token alone.
- **Kalam's role stays limited to execution.** The migration enumerates its writable columns and creates no embedded password.
- **Package reloads respect ownership tags.** load-package.sh replaces pkg:soma objects without sweeping Jodi's definitions.
- **Cookie behavior remains deployment configuration.** No route should hard-code a callback host or replace the declared Secure policy.

## Status

**8 September 2026.** The package implements fourteen routes, OAuth sessions, season administration,
submission recording, replay signing, and the shared schema. Orion 1.7.0 package lint passes; check-sql.sh provides
the database-dependent static check; authenticated HTTP behavior needs a configured stack and OAuth App. API tokens for
SDK/CLI use and an owner-scoped view of queued, cancelled, and failed matches remain unimplemented.

## More

- Local references: [migrations](migrations/), [channel contracts](channels/), and [workflow response mappings](workflows/).
- Competitor documentation is maintained as a separate mdBook; a published guide URL is not configured in this checkout.
- Related repositories: [Web](https://github.com/Tiny-Brains/web), [Jodi](https://github.com/Tiny-Brains/jodi), [Kalam](https://github.com/Tiny-Brains/kalam), [Axon](https://github.com/Tiny-Brains/axon), [DevOps](https://github.com/Tiny-Brains/devops).
- Apache-2.0: see [LICENSE](LICENSE).
