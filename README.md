# soma

Soma is the public API and schema owner for TinyBrains. It ships an Orion 1.8.1 package of REST
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
- Run models; Orion's own `models` entity evaluates a manifest's adapters and its ONNX graph on whichever node needs it.
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
| GET | /v1/admin-check | Session | **204 / 401 / 403 and no body.** An authorization probe for a reverse proxy, not a page |
| POST | /v1/submissions | Session | Record a release and declared asset hashes as a testing version |

Read routes are public unless they can return something private. The split is a property of the
channel, never of a parameter: `GET /v1/matches` omits queued, cancelled and trial rows for
everyone, and `GET /v1/me/matches` is a separate route rather than `?owner=me`, because a public
route that quietly returns more to some callers is the shape a privacy bug arrives in.

A submission must satisfy the open season's rules. Recording it does not imply acceptance:
Jodi performs admission and the trial before promotion. The callback is served by the sign-in
channel, so twenty-seven routes are implemented by twenty-six channels.

> **This table is four rows short, and they are not new.** `channels/` carries
> `/v1/games/{game}/models` (POST), `/v1/games/{game}/models/{owner}/{repo}` (GET and PATCH) and
> `/v1/versions/{id}`, none of which appear above — and the row reading `/v1/models/{id}` is the
> old spelling of that last one, from before the rebuild separated a model from its versions. Fix
> them against the channels rather than against this note; `ls channels/` is the inventory.

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

- Orion server 1.8.1 and Postgres 16 for the supported local stack.
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
| prior_mu, prior_sigma, settled_sigma | Orion vars for leaderboard priors and provisional status | Must match Jodi's rating policy |
| season_gap_days | Orion var for the minimum gap between seasons | Missing or incorrect policy changes season-opening eligibility |
| github_token | Orion var the entry create asks GitHub who owns a repository with | Empty works and is 60 requests/hour for the whole server, shared; model creation refuses when it runs out |
| GITHUB_API_BASE | Load-script substitution for the github-api connector's base | Defaults to api.github.com; a stand-in is the only way to exercise the ownership check end to end |
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
- **Only a caller-invariant route may declare `cache`.** The response-cache key covers the method, the path params and the query — so two ids cannot collide — and covers *nothing about the caller*: no cookie, no claim. Caching an authenticated channel would serve one session's body to the next. The nine that cache are the nine anonymous reads; `soma-status` is anonymous too and stays uncached, because freshness is the whole answer it gives.
- **Every channel but one is metered twice.** `rate_limit` is the outer guard and runs *before* authentication, keyed on the caller's address; `principal_rate_limit` is the quota and runs after, keyed on `auth.sub`. A channel with only the second one meters nobody until they have signed in, which is the wrong order for an anonymous flood. The exception is `soma-admin-check`, whose caller is a proxy rather than a browser — its address is one container's, so an address-keyed bucket there could only ever lock the console out of itself. **The address is only as good as the deployment's `[rate_limit] trusted_proxies`**: with that list empty Orion keys on nginx and the whole internet shares one bucket.

## Status

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

## More

- Local references: [migrations](migrations/), [channel contracts](channels/), and [workflow response mappings](workflows/).
- Design docs: [`docs/schema.md`](docs/schema.md) — the match table, its fences, and every statement the three packages run against it.
- [The competitor guide](https://github.com/Tiny-Brains/web/tree/main/docs) — the reader-facing half: the rules, the model format, the manifest, submitting, ranking and seasons. The platform section is the high-level design for someone new to the codebase.
- Related repositories: [Web](https://github.com/Tiny-Brains/web), [Jodi](https://github.com/Tiny-Brains/jodi), [Kalam](https://github.com/Tiny-Brains/kalam), [DevOps](https://github.com/Tiny-Brains/devops).
- Apache-2.0: see [LICENSE](LICENSE).
