# soma

Platform backend for TinyBrains — the system of record for competitors, model
submissions, ladders and replays.

Soma is an **[Orion](https://github.com/GoPlasmatic/Orion) v1.5.1 package**: eleven REST channels
over Postgres, declared as JSON. There is no application code.

The design and tracking documents — `scope.md` (the API), `schema.md` (the database),
`orion-gaps.md` (what Orion still cannot do) and `DESIGN.md` — are **not in this repo**. They
live in the private workspace this repo sits inside, alongside `devops/`, which holds the compose
file and Soma's instance config. References to them below name the file without linking it.

**Soma does not run matches.** A separate game manager service — not yet designed — owns the match
loop, computes TrueSkill, and admits submitted models. It writes `matches`, `ratings` and the
admission columns of `models` directly to the same database. Soma writes `users` and inserts one
`models` row; everything else it reads. See `scope.md` §3.

---

## The surface

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

Nine reads, one insert, and a login. Response shapes are in `scope.md` §2.

---

## Layout

```
connectors/    4 · soma-db, soma-blobs (R2), github, github-api
channels/     11 · one per endpoint
workflows/    11 · one per channel
migrations/    1 · 0001_init.sql
scripts/          load-package.sh — installs the above into a running server
Dockerfile        the image: upstream orion-server + this package
```

Everything carries `tags: ["pkg:soma"]`, which is what `orion-server package export --tag pkg:soma`
selects on.

---

## Version requirement

**Orion 1.5.0 or newer.** Not a preference — the package uses two things that do not exist before
it, and both fail loudly on an older server rather than misbehaving:

- `http_call.headers` values as JSONLogic, which is what lets the OAuth callback attach a bearer
  token it obtained one task earlier. On 1.4 the task fails to *deserialize*.
- `response.cookies` on a channel plus `data._orion.response.cookies` in its workflow. On 1.4 the
  channel config is an unknown field.

`orion-server lint .` on 1.4.0 reports four errors; on 1.5.1 the package is clean with
`--deny-warnings`. Check before deploying to an instance whose version you do not control.

---

## Running it

The short way is the compose stack in the workspace's `devops/` directory, which brings up Postgres,
this package and the web shell together. What follows is the same thing by hand, against an
`orion-server` on your PATH.

**1. Database.**

```bash
createdb soma
psql -d soma -f migrations/0001_init.sql
psql -d soma -c "insert into games (slug, name) values ('ants', 'Ants');"
```

**2. Environment.** Referenced as `env://` from the connectors, so they resolve at channel load — an
unset one quarantines the channel rather than serving it unauthenticated.

| | |
|---|---|
| `SOMA_DB_URL` | `postgres://…` — Soma's data |
| `SOMA_SESSION_SECRET` | HS256 key for session and OAuth-state tokens |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_BUCKET`, `R2_ACCESS_KEY`, `R2_SECRET_KEY` | replay bucket, read-only |
| `GITHUB_CLIENT_SECRET` | resolved through `[secrets]`, never `[vars]` |

Orion's *own* state (channels, workflows, traces) is separate — set `storage.url` to a second
database, or the same one. It cannot live on a container's disk; see the deployment note below.
Note `storage.url` is the one setting that does **not** resolve `env://`: it is parsed as a database
URL and an `env://` string fails the scheme check at boot. Write it literally, or pass
`ORION_STORAGE__URL` in the environment.

**3. Check the package and the config before either touches a server.** Both are offline: no
database, no running instance.

```bash
orion-server lint . --deny-warnings
orion-server -c ../devops/soma/orion.local.toml validate-config
```

`lint` reads the directory as a **set**, so it resolves the references between the three kinds —
every channel's `workflow_id`, every task's connector and its type, duplicate ids and routes. Those
are the errors a per-file check cannot see. `--deny-warnings` matters more than it looks: the
warning class it promotes, `[logic.unresolvable]`, is the one that passes every other gate and
surfaces as wrong data. See `orion-gaps.md` N1 for the four it caught here.

**4. Load the package.** Order matters — connectors, then workflows, then channels, because channel
activation requires an active workflow.

```bash
./scripts/load-package.sh
```

The script is idempotent — it deletes the package's objects before re-creating them, so it can be
re-run after an edit. That matters because an *active* workflow is immutable: a second `POST` is a
conflict, and `PUT` answers `404 No draft version found` until you `POST .../versions` first.

It reads two environment flags, both of which exist because a committed definition should not carry
a loosened default:

| | |
|---|---|
| `SOMA_ALLOW_PRIVATE_DB=1` | sets `allow_private_urls` on the database connector |
| `SOMA_COOKIE_SECURE=0` | strips `Secure` from the session and oauth-state cookies |

`SOMA_COOKIE_SECURE=0` is what makes sign-in work over plain `http://localhost`. Browsers refuse to
store a `Secure` cookie from an `http://` origin, and the failure is silent: the callback completes,
the user row is written, and the browser holds no session. It cannot be an instance variable —
Orion requires a literal boolean for a cookie's `secure` field and drops the whole cookie with only
a warning if handed JSONLogic — so the loader rewrites it. **Set it to 1 the moment there is TLS.**

`SOMA_ALLOW_PRIVATE_DB=1` covers the other half: `connectors/soma-db.json` does not carry
`allow_private_urls`. Orion's SSRF guard refuses to dial a host that resolves to a private address, and
`localhost:5432` is one:

```
Refusing to connect db connector 'soma-db': host 'localhost:5432' resolves to
private/internal IP address ::1
```

Whether a deployed instance needs the same flag depends on whether its Postgres is reached over a
private network. Keeping it out of the committed connector means the package does not ship with the
guard disabled.

For promotion between environments use `orion-server package export --tag pkg:soma` and
`package plan` / `apply` instead.

---

## Design notes

**Raw SQL, not the portable dialect.** Every read is `db_read`. Two of them cannot be expressed in
`data_query` at all — the leaderboard sorts the parent by a *joined* column, which `include` cannot
do, and match history needs the GIN containment operator `@>`, which is not in the dialect's
vocabulary. Using one style throughout beats mixing two, and it drops the `schema` block that
`data_query` requires on every task.

**Postgres builds the response JSON — cast to `text`, parsed back by a task.** Each query returns a
single `body` column built with `json_build_object` / `json_agg`. This is deliberate: a mistyped
operator inside a `map` mapping is *not an error* — it is written through as a literal object, with
no failed task and a `200` to the caller. Keeping response construction in SQL puts it somewhere a
typo is a loud error instead of a silent one.

The cost is one extra task per read. `db_read` reaches Postgres through sqlx's `Any` driver, which
has no mapping for the `json`/`jsonb` types and fails the task outright:

```
db_read query failed: error occurred while decoding column body:
error in Any driver mapping: Any driver does not support the Postgres type PgTypeInfo(Json)
```

So every `body` column is cast `::text`, and a `parse_json` task with
`source: "temp_data.rows.0.body"` reads it back into `data.body` before the response is shaped. The
task carries a `{"!!": …}` condition so an empty result set skips it rather than failing. Eight of
the nine reads do this; the sign-in callback does not, because its one column is already `id::text`.

This is not caught by `lint` — the query is opaque to it — and it is not visible until a real
Postgres is on the other end. Testing against the running server is the only gate for it.

**Query defaults are computed in a `map` task, never inline in `params`.** `db_read` folds
`{"var": …}` nodes and nothing else, so an `or` written directly into `params` reaches Postgres as a
literal object. The leaderboard and match-history workflows each open with a `defaults` task for
exactly this reason; it is not stylistic. This is the one place the general rule above — that raw
SQL is safer than mappings — does not save you, because the parameter list is JSON either way.
`orion-gaps.md` N1.

**Cookies are declared, not assembled.** The three channels that set one carry
`response.cookies: true` and their workflows write a `data._orion.response.cookies` array —
`name`, `value`, `path`, `http_only`, `secure`, `same_site`, `max_age` as fields. Orion validates
the value and spells the attributes, which is where a missing `Secure` or a `SameSite` that should
have been `Lax` otherwise comes from. It also allows more than one cookie per response, which is
what lets the OAuth callback set the session and clear the spent state cookie in one go.

**Pagination is `OFFSET`.** The cursor is the offset as a string. Correct for a ladder of hundreds,
and it drifts if rows move between pages. Keyset would need `(conservative, model_id)` compared
row-wise across a join — see `orion-gaps.md` G5.

**`provisional` is `matches_played < 20`, hardcoded in SQL.** It belongs in policy (S13, deferred).
Grep for `< 20` when that lands.

**Two statements for one submission.** `db_write` returns only `{rows_affected}`, so the row is
inserted and then read back. The race between them is closed by `UNIQUE (owner_id, game_id, version)`
turning a collision into a retry — and since 1.5.0 that collision is classified rather than opaque,
so it answers `409` on its own. See below.

**The OAuth token exchange keeps the legacy `body_logic` spelling.** `body` is the modern name for
the same field, but under `body_format: "form"` a body written as `body` is shape-checked as a
literal at authoring time and a computed entry is refused. Renaming it breaks the package.
`orion-gaps.md` N2.

---

## Status

**`/health` always says `degraded`, and it is lying.** On 1.5.1 the `trace_persistence`
background task is logged as stopped *microseconds before* it starts:

```
INFO  Audit-log writer started
ERROR Background task stopped before shutdown and cannot be restarted  task="trace_persistence"
INFO  Trace persistence queue started  mode=Async
```

The task then runs and traces do land in the state database — `select count(*) from traces`
climbs — but the health registry keeps the `failed` state it recorded, so `status` is stuck at
`degraded` for the life of the process. It is a startup-ordering bug in Orion, not a Soma problem,
and nothing is actually lost.

It matters for orchestration: a readiness probe must check that `/health` returns **200**, not that
`status == "healthy"`, or the container never comes up. the `Dockerfile`'s `HEALTHCHECK` does the
former deliberately.

---

### The rest


**Sign-in works.** It did not on 1.4 — the callback could not attach an `Authorization` header
built from a token obtained one task earlier, so the task failed to deserialize and there was no
assembled fallback. Orion 1.5.0 made every `http_call` parameter JSONLogic, which closed it. The
flow is declarative end to end: signed state token as cookie and query parameter, `jwt_verify` on
return, code exchange, `GET /user`, `jwt_sign` a 30-day session.

**`409` works, and needed no workflow code.** The one-in-flight and duplicate-release rules are
partial unique indexes. Since 1.5.0 a violation arrives classified as `integrity_unique` and an
uncaught one answers `409 CONFLICT` by itself, so `soma-submissions-create.json` catches nothing —
the run halts at the insert and the platform states the conflict. The two indexes are
indistinguishable to the workflow by design; `scope.md` wants `409` either way.

**Sessions cannot be revoked.** `DELETE /session` clears the cookie; the token stays valid until it
expires. Stateless by necessity, and the fix is Soma's rather than Orion's — a `sessions` table and
a lookup per authed request. `orion-gaps.md` G1.

**Nothing promotes a submission.** Rows land in `testing` and stay there until the game manager
exists. Soma can be finished and tested without it — seed the tables by hand — but the loop does not
close.

---

## Deployment

Orion is a Tokio/Axum binary with no WASM target, so **Cloudflare Workers cannot host it**; the
target is Cloudflare Containers behind a Worker. Container disk is ephemeral, which is why both
Soma's data and Orion's own state are managed Postgres rather than SQLite or D1 — and why D1 is not
used at all: it cannot back Orion's state, and from outside the Workers runtime its REST API is
capped by Cloudflare's global 1,200-requests-per-5-minute API limit.

Cold starts are 1–3s with a 10-minute idle sleep, which is the weakest part of the fit for a public
leaderboard. `sleepAfter` is tunable; warm time is billed.
