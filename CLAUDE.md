# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The parent `tinybrains/CLAUDE.md` covers the platform: the eight repos, the ownership boundaries
between packages, and the constants that must stay equal across them. This file covers Soma only.

## What this repo ships

No server code. Soma is an Orion **1.8.1** package — 40 channel definitions, 40 workflows, 6
connectors — plus `migrations/`, the Postgres schema **every** TinyBrains package shares. DevOps
owns the orion-server that hosts it. Behaviour lives in declarative JSON and inline SQL, so lint
plus the SQL checks are this repo's compiler; there is no test framework and nothing to build.

**Two APIs share the hostname, and the second one is newer than most of this file.** Twenty-six
routes are the site's, cookie-authed. Thirteen more, plus one clock, are **the runner gate**:
`/v1/runner/*`, which a Kalam replica calls instead of holding a Postgres role, plus the admin
routes over `runner_keys` and `runners`. **The eight match statements live here now** — claim,
start, release, renew, finish, the roster read and the reap — moved out of
`kalam/scripts/gen-kalam.py` unchanged. Three things about them are not like the rest of the
package:

- they verify a **bearer JWT with `aud: "runner"`** (`constants.runner_auth`), not the session
  cookie, and have their own rate constants because `per_user_write_rate` is 1 rps and a claim loop
  is 0.8;
- `soma-runner-reap` is the package's **only cron channel**, and it is singular only because Soma's
  Orion is in cluster mode — the opposite of the rule for a Kalam replica;
- they run over **`soma-db`, the owner connector**, so the `kalam` role's column grant is not what
  confines them. That is a deliberate trade, argued on the grant block in `0001_init.sql` and in
  `README.md`'s What must stay true. A runner statement that wants a new grant on the `kalam` role
  is a statement on the wrong connector.

`docs/schema.md` §4 and §4a are the statements and the routes; §3.8a is `runner_keys`/`runners`.

`README.md` is the route table, the deployment settings, and the invariants. `docs/schema.md` is
the schema design **and every statement all three packages run against it** — including Jodi's and
Kalam's, which is why it is the reference when a schema change is proposed.

## Commands

Run from the repo root. All four checks are separate and cover different halves — a package that
loads is not a package that works.

```sh
./scripts/check-defs.sh            # lint + clippy + fmt, all --deny-warnings; no stack needed
./scripts/load-package.sh          # compile the set, apply the package; ORION_ADMIN picks the instance
./scripts/check-sql.sh             # PREPAREs all 38 shipped statements against a scratch schema
./scripts/smoke.sh                 # every route against a running stack: status codes only
./scripts/verify/run.sh            # what the statements MEAN: the walk, both fence races, grants
```

`check-defs.sh` is the one to run on every change: it reads the definitions and nothing else, so it
needs no database and no stack. It runs `lint`, `clippy` and `fmt` with `--deny-warnings`, and the
set is clean -- the 14 duplications this file used to say the package "cannot fix" are fixed, in
`shared/soma.json`.

| Check | Proves | Needs |
|---|---|---|
| `check-defs.sh` | the set resolves, says nothing twice, and is in house style | the 1.8.1 binary |
| `check-sql.sh` | every inline query resolves against the current schema | `tinybrains-db-1` up |
| `smoke.sh` | the workflows around those queries answer | the whole stack up, package loaded |
| `verify/run.sh` | the schema's promises to Jodi and Kalam hold | `tinybrains-db-1` up |

**Narrowing a failure.** `check-sql.sh` `\echo`s `workflow-id / task-id` before each `PREPARE`, so
a failure names the exact task; to iterate on one, copy its `query` out and `PREPARE` it by hand
against `soma_sqlcheck`. `smoke.sh` has no filter — curl the single route instead (it prints the
`curl` shape for each). Env: `DB_CONTAINER`/`DB_USER` (default `tinybrains-db-1`), `BASE`,
`SMOKE_HANDLE` (default `codetiger`), `SOMA_ENV_FILE` (default `../devops/.env`), `SEED`,
`ORION_ADMIN`, `ORION_ADMIN_API_KEY`, `SOMA_ALLOW_PRIVATE_DB=1` for a private DB address.

**The toolchain trap.** `orion-server` must be **1.8.x**; an older one does not understand this
package's auth, cron or plugin blocks and reports *misleading schema errors* on definitions that
are correct. `check-defs.sh` asserts the version before it runs anything, so the trap is now a
message rather than a puzzle. The pinned source of truth is the separate checkout at
`~/Development/Plasmatic/Orion-Projects/Orion`; `devops/compose/orion/` holds the image and the
`soma.toml.tmpl` instance template.

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
  released. `runner_keys`, `runners`, `live_runners` and `matches.played_by` went in that way rather
  than as an `0003_`, and `check-sql.sh:29` / `verify/run.sh` hardcode `cat 0001 0002`, so a third
  file would be invisible to all three. A schema change must pass *every* consumer's
  `check-sql.sh` (soma, jodi, kalam) before it lands, and `verify/run.sh` walks Jodi's and Kalam's
  statements too.
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

- **Never hand-transcribe a statement into `scripts/verify/`.** Both this repo's copies of Kalam's
  SQL — `docs/schema.md` §4 and `verify/statements.sql` — carried the pre-R7 two-CTE wave claim for
  months after a one-row claim shipped, so every fence race the harness "proved" was proving a
  statement that did not exist. `run.sh` now compares `statements.sql` against the shipped workflows
  and refuses to run on a difference. Regenerate rather than retype.
- `load-package.sh` retires **by tag** (`pkg:soma`) anything the compiled artifact does not carry,
  so a deleted channel releases its route. Never drop the `"tags": ["pkg:soma"]` from a definition —
  an untagged object survives every reload and holds its route forever.
- **`package apply` orders and activates; nothing here does it by hand.** It stages connectors, then
  workflows, then channels, activates in dependency order and reloads the engine once. It is also
  atomic on failure: a bad artifact leaves the running package untouched, which the old
  delete-then-POST loop could not.
- A route that can return something private gets its **own path**, never a parameter:
  `GET /v1/me/matches` exists rather than `GET /v1/matches?owner=me`, because a public route that
  quietly returns more to some callers is the shape a privacy bug arrives in.
- Session revocation must keep working before JWT expiry — that is what the `live_sessions` join
  buys. Nothing may trust a signed token alone.
- `prior_mu`, `prior_sigma`, `settled_sigma` and `forfeit_strikes` are Orion `[vars]` here and must
  equal Jodi's and Kalam's; `devops/scripts/check/configs.sh` checks several of them.
- Cookie transport (`cookie_secure`), `app_url` and `oauth_redirect_uri` are deployment vars. No
  route may hard-code a callback host or replace the declared Secure policy.
- Update `README.md`'s **Status** section when work lands. Commits go
  straight to `main`; subjects are imperative and describe the behaviour change
  ("Give Jodi its own database role"), not the files touched.
