# soma

Platform backend for TinyBrains — the system of record for competitors, model
submissions, ladders and replays.

Soma is an **[Orion](https://github.com/GoPlasmatic/Orion) v1.7.0 package**: ten REST channels
over Postgres, declared as JSON. There is no application code.

The design and tracking documents — `scope.md` (the API), `schema.md` (the database),
`DESIGN.md`, and the v2 layers under `design/v2/` (`00-overview.md`, `01-match-table.md`,
`02-jodi.md`, and the `tracker.md` that orders the build) — are **not in this repo**. They live in
the private workspace this repo sits inside, alongside `devops/` (`Tiny-Brains/devops`), which holds
the compose file and Soma's instance config. References to them below name the file without linking
it. Notes once cited as `orion-gaps.md` N-numbers are recorded inline where they matter; that file
was folded into the v2 layers and no longer exists.

**Soma does not play matches.** Under v2 the work splits three ways, one repo each, with
`devops/` deciding how they are deployed. **Jodi** — the sibling `jodi` repo — pairs matches, folds
finished ones into ratings, promotes verified versions and withdraws stale queued rows; it is three
cron channels and two plugins, loaded into this server today. **Kalam** is a second Orion package on its own replicas
that plays the matches; it holds a database role that can `SELECT` `matches` and `match_seats` and
`UPDATE` only its own columns of each, and it touches nothing else. The **Model Loader** is a
separate binary beside each of them, running competitor models and their adapters. Soma owns the
schema all three share, and the admission workflow that verifies a submission through the loader
beside it. See `design/v2/00-overview.md` §2 and `scope.md` §3.

---

## The surface

Eleven REST routes. Nothing else: Soma is the read and write surface for competitors, and the
clocks that run the ladder are the **jodi** package in its own repo — loaded into this same
orion-server today, but that is `devops/`'s choice rather than a fact about either repo.

| Method | Path | Auth |
|---|---|---|
| `GET` | `/v1/auth/github` | — |
| `GET` | `/v1/auth/github/callback` | — |
| `GET` | `/v1/me` | session |
| `DELETE` | `/v1/session` | session |
| `GET` | `/v1/games` | — |
| `GET` | `/v1/games/{game}/leaderboard?ladder=&limit=&cursor=` | — |
| `POST` | `/v1/submissions` | session |
| `GET` | `/v1/models?game=` | session |
| `GET` | `/v1/models/{id}` | — |
| `GET` | `/v1/matches?model=&limit=` | — |
| `GET` | `/v1/matches/{id}` | — |

Eleven routes on ten channels: the sign-in channel serves both `/v1/auth/github` and its callback.
Response shapes are in `scope.md` §2.

---

## Layout

```
connectors/    3 · soma-db, soma-blobs (R2), github-api
channels/     10 · one per endpoint; soma-auth-github carries the oauth2_login block
workflows/    10 · one per channel
migrations/    2 · 0001_init.sql, 0002_sessions.sql
scripts/          load-package.sh — installs the above into a running server
Dockerfile        the image: upstream orion-server + this package
```

Everything carries `tags: ["pkg:soma"]`, which is what `orion-server package export --tag pkg:soma`
selects on and what `load-package.sh` sweeps before reloading. The files are in `orion-server fmt`'s
house style.

---

## Version requirement

**Orion 1.7.0 or newer.** Not a preference — the package uses two things that do not exist before
it, and both are refused at create on an older server rather than misbehaving:

- **`var://` in `oauth2_login.redirect_uri`.** The sign-in channel's callback URL is
  `var://oauth_redirect_uri`, read from the instance config's `[vars]` like the app URL and the
  cookie flag. On 1.6.0 that field took no reference at all — create-time validation stripped every
  `var://` before the shape check and reported the required field missing — so the loader rewrote it
  from the environment. It does not any more.
- **`principal_rate_limit` on a channel.** Every session-authed channel carries a quota keyed on the
  verified `sub` claim. On 1.6.0 the block is an unknown config field.

A third 1.7.0 change matters less but is worth knowing: `db_read` now binds each placeholder to the
type PostgreSQL declares for it, not to the JSON value's shape. Soma's query defaults are still
strings, so the package would still bind one type per placeholder on 1.6.0 — the rule is simply no
longer load-bearing, and a value that will not convert is a `400` naming the placeholder instead of
a `500` from inside Postgres.

1.6.0 brought the two things the package's *shape* depends on — `config.oauth2_login`, which is what
the sign-in channel is (before it the same flow was two channels, two workflows and thirteen tasks),
and SQL connectors on the real Postgres driver, which is why every read returns a `json` column and
reads it as the document. 1.7.0 is a superset.

`orion-server fmt --check .`, `lint . --deny-warnings` and `clippy . -c <config>` on 1.7.0 are clean,
apart from `clippy`'s five `duplication.repeated_value` style warnings. Check before deploying to an
instance whose version you do not control.

---

## Running it

The short way is the compose stack in the workspace's `devops/` directory, which brings up Postgres,
this package and the web shell together. What follows is the same thing by hand, against an
`orion-server` on your PATH.

**1. Database.**

```bash
createdb soma
psql -d soma -f migrations/0001_init.sql
psql -d soma -f migrations/0002_sessions.sql
psql -d soma -c "insert into games (slug, name) values ('ants', 'Ants');"
```

**2. Environment.** Referenced as `env://` from the connectors and the sign-in channel, so they
resolve at load — an unset one quarantines the channel rather than serving it unauthenticated.

| | |
|---|---|
| `SOMA_DB_URL` | `postgres://…` — Soma's data |
| `ORION_STATE_DB_URL` | `postgres://…` — Orion's own state, read by `[storage] url = "env://ORION_STATE_DB_URL"` |
| `SOMA_SESSION_SECRET` | HS256 key for session tokens and the sign-in state cookie; at least 32 bytes |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | the OAuth App, read by the sign-in channel |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_BUCKET`, `R2_ACCESS_KEY`, `R2_SECRET_KEY` | replay bucket, read-only |

Orion's *own* state (channels, workflows, traces) is separate — a second database, or the same one.
It cannot live on a container's disk; see the deployment note below. Since 1.6.0 `storage.url`
takes an `env://` reference like every other value in the config file.

The App's callback URL is not an environment variable on the host: it is `[vars] oauth_redirect_uri`
in the instance config, beside `app_url` and `cookie_secure` — see step 4.

**3. Check the package and the config before either touches a server.** All three are offline: no
database, no running instance.

```bash
orion-server lint . --deny-warnings
orion-server clippy . -c ../devops/soma/orion.local.toml --deny-warnings
orion-server -c ../devops/soma/orion.local.toml validate-config
```

`lint` reads the directory as a **set**, so it resolves the references between the three kinds —
every channel's `workflow_id`, every task's connector and its type, duplicate ids and routes. Those
are the errors a per-file check cannot see. `--deny-warnings` matters more than it looks: the
warning class it promotes, `[logic.unresolvable]`, is the one that passes every other gate and
surfaces as wrong data.

`clippy -c` is the one that reads the instance config, and so the one that catches a
`metadata.vars.<name>` the config does not declare — which is exactly how the session cookie once
went out with no `Secure` flag and no error. It reports `duplication.repeated_value` warnings for
the repeated channel blocks; those are style, and `--deny-warnings` there is a choice. 1.7.0 added
two `deny` rules that fit this package's shape — `correctness.unknown_input_key`, a task input key
the function does not declare and silently ignores (a `"limit"` written beside a `db_read` `query`
does nothing), and `correctness.unordered_page`, a `skip` with no `sort` — and both are quiet here.

**4. Load the package.** Order matters — connectors, then workflows, then channels, because channel
activation requires an active workflow.

```bash
./scripts/load-package.sh
```

The script is idempotent — it deletes every object tagged `pkg:soma` before re-creating the package,
so it can be re-run after an edit. That matters because an *active* workflow is immutable: a second
`POST` is a conflict, and `PUT` answers `404 No draft version found` until you `POST .../versions`
first. The sweep is by tag rather than by file so a channel this version no longer ships does not
stay active and hold its route.

It reads one environment value, which exists because the package should not ship with it:

| | |
|---|---|
| `SOMA_ALLOW_PRIVATE_DB=1` | sets `allow_private_urls` on the database connector |

`SOMA_ALLOW_PRIVATE_DB=1` covers the SSRF guard: `connectors/soma-db.json` does not carry
`allow_private_urls`. Orion refuses to dial a host that resolves to a private address, and
`localhost:5432` is one:

```
Refusing to connect db connector 'soma-db': host 'localhost:5432' resolves to
private/internal IP address ::1
```

Whether a deployed instance needs the same flag depends on whether its Postgres is reached over a
private network. Keeping it out of the committed connector means the package does not ship with the
guard disabled.

The OAuth callback URL is **not** a loader flag any more: it is `[vars] oauth_redirect_uri` in the
instance config, which the sign-in channel reads as `var://oauth_redirect_uri` and Orion resolves
when the channel loads. It must equal the callback URL registered with the OAuth App exactly, which
is a different absolute URL in every environment, and it is `https` only except on a loopback host —
a value that fails that at load quarantines the channel rather than serving it. Before 1.7.0 the
field took no reference and `load-package.sh` rewrote it from `OAUTH_REDIRECT_URI`; the container's
config now reads that variable itself, as `${OAUTH_REDIRECT_URI:-…}`. Orion refuses a non-https
redirect URI except on a loopback host.

Whether cookies carry `Secure` is `[vars] cookie_secure` the same way: a TOML boolean the state
cookie and the session cookies read. Browsers refuse to store a `Secure` cookie from an `http://`
origin, so a plain-http development instance declares `false`; every deployed instance declares
`true`.

For promotion between environments use `orion-server package export --tag pkg:soma` and
`package plan` / `apply` instead.

---

## Design notes

**Raw SQL, not the portable dialect.** Every read is `db_read`. Two of them cannot be expressed in
`data_query` at all — the leaderboard sorts the parent by a *joined* column, which `include` cannot
do, and match history needs the GIN containment operator `@>`, which is not in the dialect's
vocabulary. Using one style throughout beats mixing two, and it drops the `schema` block that
`data_query` requires on every task. Since 1.6.0 `db_read` refuses a statement that is not a read,
which is what makes the connector's `delete: false` mean something.

**Postgres builds the response JSON.** Each query returns a single `body` column built with
`json_build_object` / `json_agg`. This is deliberate: a mistyped operator inside a `map` mapping is
*not an error* — it is written through as a literal object, with no failed task and a `200` to the
caller. Keeping response construction in SQL puts it somewhere a typo is a loud error instead of a
silent one. The respond task copies `temp_data.rows.0.body` into `data.body` and shapes the
response; an empty result set is a null body.

Before 1.6.0 every `body` column was cast `::text` and parsed back by a `parse_json` task, because
`db_read` went through a driver layer that could not decode `json`. Those nine tasks are gone, and
so is the reason the reads could not be tested against an empty table.

**Query defaults are computed in a `map` task, never inline in `params`.** `db_read` folds
`{"var": …}` nodes and nothing else, so an `or` written directly into `params` reaches Postgres as a
literal object; the leaderboard and match-history workflows each open with a `defaults` task for
exactly this reason. The defaults are the strings `"50"`, `"0"` and `"25"` —
the type a query-string value arrives as. Since 1.7.0 the spelling is a matter of taste: a
placeholder is bound to the type the query declares for it, so `"50"` and `50` both reach
`LIMIT ($3)::int` as an integer, and a value that will not convert is a `400` naming the placeholder
and its declared type. Before 1.7.0 the JSON type chose the SQL type and the first call froze it,
which is why the strings used to be a rule; since 1.6.0 a placeholder's declared type converts, so
the spelling no longer matters.

**Cookies are declared, not assembled.** The two workflows that set one carry
`response.cookies: true` on their channel and write a `data._orion.response.cookies` array — `name`,
`value`, `path`, `http_only`, `secure`, `same_site`, `max_age` as fields. Orion validates the value
and spells the attributes. `secure` reads `metadata.vars.cookie_secure`, and the sign-in channel's
state cookie reads the same var as `var://cookie_secure`, so the three cookies agree by
construction. Since 1.6.0 a cookie Orion refuses is recorded on the trace's `errors` rather than
dropped in silence.

**The sign-in is Orion's, the session is Soma's.** `channels/soma-auth-github.json` names the
provider, the scopes, the callback path and where the client id and secret come from; Orion mints
the state, binds it to the callback, runs PKCE and exchanges the code. The workflow starts with a
verified `metadata.oauth.access_token`, fetches `GET /user`, upserts the user, writes a `sessions`
row and signs the 30-day token. A refused callback — forged or missing state, a spent code, a user
who pressed Cancel — answers `401` from the channel and never enters the workflow.

**Quotas are per competitor, and Orion's.** Every session-authed channel carries
`principal_rate_limit` keyed on `{"var": "auth.sub"}` — the user id, from claims Orion has already
verified — at 10 requests per second with a burst of 20, and 1 per second with a burst of 5 on
`POST /v1/submissions`. It runs after authentication and answers `429` with `Retry-After`; an
anonymous route has no principal and no quota, and no address-keyed `rate_limit` is declared — that
is the gateway's job. This is a burst control, not the daily submission quota `platform.md` S3
describes; that is a counter and belongs with policy (S13).

**Pagination is `OFFSET`, and stays so on purpose.** The cursor is the offset as a string. Orion
1.7.0 added a keyset cursor — `after` in `data_query`, and the raw-SQL recipe under `db_read` — and
the leaderboard does not use it: the sort key is a live rating that every match rewrites, so a
keyset position moves between pages exactly as an offset does, and `rank` is a position in the
whole ladder either way. Keyset is the tool for a table whose sort keys hold still, `created_at, id`
say, which the match history would be if it paged.

**`provisional` is `matches_played < 20`, hardcoded in SQL.** It belongs in policy (S13, deferred).
Grep for `< 20` when that lands.

**Two statements for one submission.** `db_write` returns only `{rows_affected}`, so the row is
inserted and then read back. The race between them is closed by `UNIQUE (owner_id, game_id, version)`
turning a collision into a retry — and since 1.5.0 that collision is classified rather than opaque,
so it answers `409` on its own. See below.

**Refusals are `deny` tasks: a `condition` on the failing case, `terminal: true`, and a chosen
status.** 1.6.0 added `halt_on: "failure"`, which stops a run at a task that recorded `4xx`, but a
halted task answers `400` and the shell keys on `401` exactly — so the session guard keeps shaping
its own status, placed before `respond` so a rejection is the first word rather than the last. The
join on `live_sessions` is what enforces the rule; `deny` only names the outcome.

---

## Status

**Sign-in is native.** One channel, seven tasks in the workflow, PKCE included. Verified by
request on 1.7.0: `GET /v1/auth/github` answers `302` to GitHub carrying `state`, `scope=read:user`,
an S256 `code_challenge` and the `redirect_uri` resolved from `[vars] oauth_redirect_uri`, and sets
`soma_oauth_state`; a callback with a forged state answers `401` and reaches no GitHub endpoint; the
workflow half ran under `dry-run` on 1.6.0 with the grant at `metadata.oauth` and the connectors
stubbed, and is unchanged. The GitHub leg — consent, code exchange — is the one step only a browser
exercises: sign in once through the shell after a deploy.

**The quota fires.** Verified by request on 1.7.0 with a hand-minted session: `GET /v1/me` admits
the burst and then answers `429 RATE_LIMITED` with `Retry-After: 1`, while `GET /v1/games`, which has
no principal, answers `200` to the same burst.

**The session path is verified end to end** against the compose stack with a hand-minted token:
`/v1/me` and `/v1/models` answer `200` with real rows, `POST /v1/submissions` answers `201` and a
repeat `409`, `DELETE /v1/session` answers `200` and clears the cookie, and every session-gated
route then answers `401 session_revoked` — the `deny` tasks, not the channel guard, because the
token is still valid and only its row is dead.

**`409` works, and needed no workflow code.** The one-in-flight and duplicate-release rules are
partial unique indexes. Since 1.5.0 a violation arrives classified as `integrity_unique` and an
uncaught one answers `409 CONFLICT` by itself, so `soma-submissions-create.json` catches nothing —
the run halts at the insert and the platform states the conflict. The two indexes are
indistinguishable to the workflow by design; `scope.md` wants `409` either way.

**Sessions are revocable.** The token carries a `sid` claim naming a row in `sessions`, and every
statement in an authed workflow joins the `live_sessions` view on it, so `DELETE /session` ends the
token rather than merely clearing the cookie. The check is a `JOIN` rather than a guard task
because it costs no extra round trip, cannot be omitted by mistake, and — unlike a JSONLogic
guard — cannot fail open.

**Trace persistence is a free choice.** `trace_storage.mode` is `sync`, Orion's default, and the
write costs 2.1 ms median on `GET /v1/games`. Before 1.6.0 it had to be: `async` and `batch`
mis-registered their worker as failed and pinned `/health` to `degraded` for the life of the
process. That is fixed, the image's `HEALTHCHECK` now uses `/readyz`, and the mode can change when
volume says so.

**The ladder runs, and it is Jodi's.** Three cron channels and two plugins live in the sibling
`jodi` repo, loaded into this server by `devops/`. Verified end to end against the local stack: a
`verified` version gets a trial, is promoted, and a finished match folds to a rating that reaches
`GET /v1/games/{game}/leaderboard`. See `jodi/README.md`.

**Soma's read shapes speak the two-table match.** A match's players come from `match_seats` rather
than three positionally-aligned arrays, and the match object carries its public status, why it was
withdrawn and what replaced the seat, the fault and its seat, both digests, per-seat strikes, and
the rating change each seat took. `scripts/check-sql.sh` PREPAREs every query the package ships
against a schema built from the migrations — it caught two workflows still reading
`matches.model_ids` the day the schema changed.

**Nothing admits a submission.** A row lands in `testing` and stays there: the admission workflow
needs a Model Loader to `inspect` and `validate` against, and that binary does not exist yet
(`design/v2/tracker.md` P3 and P5). That is the one hand still on the loop.

**Nothing plays a match.** Kalam's package exists; its wave workflow waits on layer 03 and the
engine. Until then a match is finished by hand to exercise Jodi.

---

## Deployment

Orion is a Tokio/Axum binary with no WASM target, so **Cloudflare Workers cannot host it**; the
target is Cloudflare Containers behind a Worker. Container disk is ephemeral, which is why both
Soma's data and Orion's own state are managed Postgres rather than SQLite or D1 — and why D1 is not
used at all: it cannot back Orion's state, and from outside the Workers runtime its REST API is
capped by Cloudflare's global 1,200-requests-per-5-minute API limit.

Cold starts are 1–3s with a 10-minute idle sleep, which is the weakest part of the fit for a public
leaderboard. `sleepAfter` is tunable; warm time is billed.
