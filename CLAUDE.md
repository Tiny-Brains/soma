# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The parent `tinybrains/CLAUDE.md` covers the platform: the nine repos, the ownership boundaries
between packages, and the constants that must stay equal across them. This file covers Soma only.

## What this repo ships

No server code. Soma is an Orion **1.8.1** package — 22 channel definitions, 22 workflows, 3
connectors — plus `migrations/`, the Postgres schema **every** TinyBrains package shares. DevOps
owns the orion-server that hosts it. Behaviour lives in declarative JSON and inline SQL, so lint
plus the SQL checks are this repo's compiler; there is no test framework and nothing to build.

`README.md` is the route table, the deployment settings, and the invariants. `docs/schema.md` is
the schema design **and every statement all three packages run against it** — including Jodi's and
Kalam's, which is why it is the reference when a schema change is proposed.

## Commands

Run from the repo root. All four checks are separate and cover different halves — a package that
loads is not a package that works.

```sh
./scripts/load-package.sh          # sweep pkg:soma objects, re-POST; ORION_ADMIN picks the instance
orion-server lint . --deny-warnings   # references, schemas, every declared env var
orion-server clippy .              # advisory; reports 14 known duplications this package cannot fix
orion-server fmt --check .         # definition-JSON house style; drop --check to apply
./scripts/check-sql.sh             # PREPAREs all 38 shipped statements against a scratch schema
./scripts/smoke.sh                 # every route against a running stack: status codes only
./scripts/verify/run.sh            # what the statements MEAN: the walk, both fence races, grants
```

| Check | Proves | Needs |
|---|---|---|
| `lint` | definitions reference things that exist | the 1.8.1 binary |
| `check-sql.sh` | every inline query resolves against the current schema | `tinybrains-db-1` up |
| `smoke.sh` | the workflows around those queries answer | the whole stack up, package loaded |
| `verify/run.sh` | the schema's promises to Jodi and Kalam hold | `tinybrains-db-1` up |

**Narrowing a failure.** `check-sql.sh` `\echo`s `workflow-id / task-id` before each `PREPARE`, so
a failure names the exact task; to iterate on one, copy its `query` out and `PREPARE` it by hand
against `soma_sqlcheck`. `smoke.sh` has no filter — curl the single route instead (it prints the
`curl` shape for each). Env: `DB_CONTAINER`/`DB_USER` (default `tinybrains-db-1`), `BASE`,
`SMOKE_HANDLE` (default `codetiger`), `SOMA_ENV_FILE` (default `../devops/.env`), `SEED`,
`ORION_ADMIN`, `ORION_ADMIN_API_KEY`, `SOMA_ALLOW_PRIVATE_DB=1` for a private DB address.

**The toolchain trap, and it bites.** `orion-server` on PATH here is **1.5.1**. It does not
understand this package's auth, cron or plugin blocks and reports *misleading schema errors* on
definitions that are correct. The pinned 1.8.1 source of truth is the separate checkout at
`~/Development/Plasmatic/Orion-Projects/Orion`; `devops/compose/Orion/` holds the image and the
`soma.toml.tmpl` instance template. Check `orion-server --version` before believing a lint failure.

## How a route is built

Each route is a `channels/soma-*.json` + `workflows/soma-*.json` pair with matching filenames.
**Channels declare transport**: method, `route_pattern`, `auth` (HS256 JWT read from the
`soma_session` cookie, issuer `soma`), the two rate limits — `rate_limit` keyed on the caller's
address and applied *before* auth, `principal_rate_limit` keyed on `auth.sub` and applied after —
and `response.mode: "shaped"`. **Workflows are a flat task list** that ends by writing
`data.body` and `data._orion.response` (`{status, body_path}`) — that map task *is* the response.
Sign-in and sign-out additionally declare `cookies` on the response; sign-in also `allowed_headers`.

Every workflow's `description` field carries the design argument for that route. Read it before
changing the route — it is where the reasoning lives, not in a comment.

One route breaks the second half of that shape and is meant to: `soma-admin-check` writes a status
and **no body at all**. It is an authorization probe for a reverse proxy — nginx's `auth_request`
allows on 2xx and denies on 401/403 — which is how the Orion console at `devops/compose/orion-ui/`
is put behind this platform's own GitHub sign-in. Change its statuses and you change who can open
that console, so the split is documented in its `description` rather than inferred.

Three shapes recur across the 23 workflows:

- **SQL builds the response, the workflow moves it.** Queries end `SELECT json_build_object(...)
  AS body`, and the respond task maps `temp_data.rows.0.body` straight out. Response shaping in
  JSONLogic is the exception, not the rule.
- **The session guard is a JOIN, not a task.** Authed reads join `live_sessions s ON s.user_id =
  u.id AND s.sid = ($2)::uuid` with `metadata.auth.claims.sub`/`.sid`. No row → a terminal task
  answers 401 `session_revoked`. It costs no extra round trip and cannot be forgotten. Admin routes
  read `role` off that same live row (never off a cookie claim) so a demotion takes effect at once.
  `soma-models-list` is the documented exception: `json_agg` with no `GROUP BY` returns a row
  whatever it is fed, so its guard cannot be inside the aggregate.
- **Write, then diagnose.** `db_write` answers only `rows_affected`, so a refusal is: one statement
  that does the work; a conditional `db_read` that asks *why* nothing happened; a terminal map that
  turns that into an error code. See `soma-seasons-create` (`create` → `why` → `refused`).

## Orion constraints that shape every statement

`docs/schema.md` §2 is normative, verified against the 1.7.0 source and re-checked at 1.8.1 (the
only change to `db_write.rs` between them is sqlx 0.9's `AssertSqlSafe` wrapper, same semantics). The load-bearing ones:

1. `db_write` returns `rows_affected` and nothing else — no `RETURNING` reaches the workflow, so a
   created row is read back in a second task.
2. **One statement per task, each its own transaction.** Anything that must be atomic is one
   statement; data-modifying CTEs are allowed in `db_write` and refused in `db_read`.
3. `params` elements fold `{"var": ...}` and nothing else. A computed value needs a `map` task first.
4. Every placeholder is cast explicitly as `($n)::type` — `check-sql.sh` leaves inference to
   Postgres and a statement that stopped doing this would be ambiguous to the server too.

## The schema is the interface

- **`migrations/0001_init.sql` is rewritten in place**, not extended with ALTERs — nothing is
  released. A schema change must pass *every* consumer's `check-sql.sh` (soma, jodi, kalam) before
  it lands, and `verify/run.sh` walks Jodi's and Kalam's statements too.
- **A shape many routes return is defined once, in the migration**: `season_json()`,
  `season_state()`, `current_season()`, `model_phase()`, `model_ratings()`, `match_seat_rows()`,
  and the two `season_admits*()` predicates. Six routes return a season; three print a rank; the
  submission rules are asked once by the INSERT that must not happen and once by the read that
  explains why. A second copy is two pages that disagree with no way to notice.
- **Constraints enforce what no writer is trusted with**: the partial unique indexes
  (`models_one_in_flight_uniq`, `seasons_one_live_uniq`) and the exclusion constraint are the rules.
- **Grants are the ownership boundary**, at the bottom of `0001_init.sql`: `kalam` gets SELECT on
  two tables and UPDATE on named columns; `jodi` owns the version life cycle. Soma inserts a
  `models` row and owns `users`/`sessions`. Soma writing a result or a rating is a review failure.
- `seasons.weight_classes` is validated **strictly ascending** — admission takes the first class a
  size fits, so an out-of-order table silently makes a class unreachable.

## What breaks if you forget it

- `load-package.sh` sweeps **by tag** (`pkg:soma`), not by the files present, so a deleted channel
  releases its route. Never drop the `"tags": ["pkg:soma"]` from a definition — an untagged object
  survives every reload and holds its route forever.
- Workflows load before channels (a channel holds its workflow); an ACTIVE workflow is immutable in
  Orion, so reload is delete-then-create, never PUT.
- A route that can return something private gets its **own path**, never a parameter:
  `GET /v1/me/matches` exists rather than `GET /v1/matches?owner=me`, because a public route that
  quietly returns more to some callers is the shape a privacy bug arrives in.
- Session revocation must keep working before JWT expiry — that is what the `live_sessions` join
  buys. Nothing may trust a signed token alone.
- `prior_mu`, `prior_sigma`, `settled_sigma` and `forfeit_strikes` are Orion `[vars]` here and must
  equal Jodi's and Kalam's; `devops/scripts/check/configs.sh` checks several of them.
- Cookie transport (`cookie_secure`), `app_url` and `oauth_redirect_uri` are deployment vars. No
  route may hard-code a callback host or replace the declared Secure policy.
- Update `README.md`'s **Status** section and `design/tracker.md` when work lands. Commits go
  straight to `main`; subjects are imperative and describe the behaviour change
  ("Give Jodi its own database role"), not the files touched.
