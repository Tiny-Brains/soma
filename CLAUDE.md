# CLAUDE.md

Soma is an Orion 1.8.1 package plus the Postgres migrations every TinyBrains package shares, shipped
as the node image `ghcr.io/tiny-brains/soma`. There is no server code. Behaviour is JSON channel and
workflow definitions with inline SQL, generated clock files, connectors and two Rust/wasm plugins,
so `orion-server lint`/`clippy` and the SQL checks act as the compiler. `README.md` is the human
guide: routes, clocks, configuration, operating a season, production requirements, invariants and
known gaps. The parent `tinybrains/CLAUDE.md` holds the contracts that cross into kalam, ants, web and
the cli. When you close a gap or find one, update README's **Known gaps**.

## Checks

```sh
./scripts/check-defs.sh                          # every change: generator drift, lint, clippy, fmt, the Bearer space; no stack
python3 scripts/gen-clocks.py                    # after editing a clock; commit the regenerated tb-*.json with it
cargo test --manifest-path plugins/Cargo.toml    # after touching plugins/ (clippy there is clean; the allows are deliberate)
./scripts/check-sql.sh                           # after any SQL or schema change; needs tinybrains-db-1
./scripts/verify/run.sh                          # after a gate, clock, notification or schema change; needs tinybrains-db-1
./scripts/smoke.sh                               # against a running stack with the package loaded
docker run --rm --entrypoint orion-server ghcr.io/tiny-brains/soma clippy /pkg/soma --deny-warnings
```

- After a schema change, run kalam's `check-sql.sh` too.
- **`verify/run.sh` exits 0 through a scenario error.** Read the output, not the exit code. Many
  `ERROR` lines are deliberate negative fixtures, so diff against a run from a `git archive HEAD`
  copy to tell a new error from an old one.
- `check-sql.sh` echoes `workflow / task` before each `PREPARE`, so a failure names the task.
  `smoke.sh` has no filter: curl the one route instead. Script env: `DB_CONTAINER`, `DB_USER`,
  `BASE`, `SMOKE_HANDLE`, `SOMA_ENV_FILE`, `SEED`.
- **`orion-server` must be 1.8.x.** An older binary reports misleading schema errors on correct
  definitions (`unknown variant 'cron'`, unknown plugin functions), and `check-defs.sh` and the
  generator both refuse to run on one. The pinned source of truth is the Orion checkout at
  `~/Development/Plasmatic/Orion-Projects/Orion`, not the local binary.
- A plugin's digest moves only when its source does. When it moves, web's
  `scripts/setup/sign-plugins.sh` must run again, or the self-load stops the node on a quarantined
  channel.

## Rules

### Routes

- A route is `channels/soma-<name>.json` + `workflows/soma-<name>.json`. The channel declares
  transport: method, `route_pattern`, `auth`, `rate_limit` (keyed on the address, before auth),
  `principal_rate_limit` (keyed on `auth.sub`, after) and `response.mode: "shaped"`. The workflow is
  a flat task list whose last `map` writes `data.body` and `data._orion.response`.
- Constants and fragments (`refuse`, `deny-revoked`) live in `shared/soma.json`, referenced with
  `$from`/`use`. So the set must be **compiled** before it is applied, which `load-package.sh` does.
- **A workflow's `description` is where a route's reasoning lives.** Read it before changing the
  route. Orion refuses one over 2048 characters, and `check-sql.sh` fails first.
- **SQL builds the response and the workflow moves it**: queries end `json_build_object(...) AS
  body`. Shaping a response in JSONLogic is the exception.
- **The session guard is a JOIN on `live_sessions` inside the query**, never a guard task. Admin
  routes read `role` off that live row, never off a cookie claim, so a demotion takes effect at once.
  Where `json_agg` without `GROUP BY` would return a row regardless (`soma-models-list`, the
  preflight), `live_sessions` is the outer `FROM`.
- **Write, then diagnose.** `db_write` answers only `rows_affected`, so a refusal is one statement
  that does the work, a conditional `db_read` that asks why nothing happened, and a terminal map that
  turns that into an error code (`soma-seasons-create`: `create` → `why` → `refused`).
- A route that can return something private gets its **own path** (`/v1/me/matches`), never a
  parameter on a public route.
- **Only a caller-invariant route may declare `cache`.** The response-cache key carries method,
  path params and query, and nothing about the caller.
- Every definition, and the generator's output, keeps `"tags": ["pkg:soma"]`. `load-package.sh`
  retires by that tag whatever the artifact no longer carries, so an untagged object holds its route
  for ever.
- `/v1/admin-check`'s 204/401/403 and its missing body are a contract with nginx `auth_request`.
- No route hard-codes a callback host or the cookie's Secure policy: `app_url`,
  `oauth_redirect_uri` and `cookie_secure` are deployment `[vars]`.

### Clocks

- **`scripts/gen-clocks.py` is the source.** The generated `channels|workflows/tb-*.json` are
  committed and loaded, but never hand-edited: a hand edit is reverted by the next regeneration, and
  `--check` fails on it first. `sql()` strips `--` comments, so comments inside clock SQL never reach
  the JSON.
- `group_runs()` folds consecutive tasks sharing a condition into a task group. **Anything that
  walks a clock workflow must descend into groups**, or it silently skips most of the statements.
- **`scripts/autoscaler.sql` is generated from `P_DEMAND_DOC`**, pair's CTEs up to its final
  `SELECT json_build_object(`, so keep that split point and the CTE names `wants` and `depth`.
  The CTEs bind `$1`–`$4` and `$6`; pair's `$5` (the depth target) is only in its final SELECT,
  which is why the autoscaler can take `$5` for itself. A new CTE parameter changes both.
- **`tb-probe` is closed to HTTP by `probe_auth`**, an audience no route mints. Orion checks a
  channel's `auth` for HTTP callers and never for `channel_call`, which is the only way the admit
  walk reaches it. Never give it a rate limit: that one does apply to `channel_call`.
- The loop shape: `loop: {counter: "i", max: N}` replays the whole task list every sweep.
  `first_sweep()` tasks run on sweep 0, a `more` filter with `on_reject: "halt"` is the real
  terminator, and `temp_data` survives a sweep, so every per-item slot is cleared as the item is
  taken.
- **Correctness rests on SQL fences, never on the singleton.** Count claims a run fence on
  `clocks.count` and every ladder write re-reads it `FOR SHARE`. Pair checks the roster epoch in
  every insert. Admission writes only under its row's `admit_token`. Withdraw is idempotent. Anything
  that changes who contests (promotion, rejection, a close, a baseline flip, an engine patch) bumps
  `clocks.epoch` where `key = 'roster'`.
- **Only count writes a ladder**, and no clock deletes (`soma-db` sets `operations.delete = false`).
  That a clock never reads `sessions` or rewrites an entry is enforced by review, not by a grant.
- `tb.pairing` decides quality, never correctness. It must stay pure and seeded by the occurrence
  id, and every correctness rule (seat count from the board, contesting, self-pairing) is repeated
  in `P_INSERT`. Trials are picked in SQL (`P_TRIALS`), not by the plugin. `tb.rating` refuses a
  missing parameter rather than defaulting one, and its output is the fold's `$4` exactly.
- **Admission branches on whose fault it is, not on the reason word.** A node verdict of `failed` is
  the competitor's and rejects the version. No verdict at all is ours: the claim is released and the
  attempt given back.
- **The manifest is fetched twice, deliberately**: as text (the exact bytes, which the declared
  hash and the stored copy are over) and parsed (to build the registration). What is registered is
  rebuilt field by field with `name` forced to `tb.v<uuid>`, so a `reference` to someone else's key
  has nowhere to survive.
- Trials feed no ladder, and a loss alone never rejects a candidate.
- A baseline lands `disabled`, and every reader of `status = 'active'` leaves it out. A new roster
  reader that asks for more must decide what a switched-off baseline means to it.
- **A notification is never part of the statement that decided the thing.** Each writer is its own
  `continue_on_error` `db_write` after the decision. It reads the decision off the row (never off
  `temp_data`), asks `notification_wanted()` inside its INSERT, and is
  `ON CONFLICT (user_id, dedupe_key) DO NOTHING`. Web's bell reads `data`'s keys, so renaming one
  silently stops a chip drawing.

### Schema

- **The schema is `migrations/0001_init.sql` and `0002_sessions.sql`, rewritten in place**, with
  no ALTERs and no third file (`check-sql.sh` and `verify/run.sh` name exactly these two). A change
  must pass kalam's `check-sql.sh` too.
- **`bootstrap` hashes every byte of the migrations, comments included**, and refuses a database
  with a different digest. Any edit, even a comment, means rebuilding the local database, so never
  touch them for cosmetics.
- A shape several routes return is a function in the migration (`season_json`, `current_season`,
  `model_phase`, `model_ratings`, `ladder_field`, `match_seat_rows`, the `season_admits*`
  predicates). Never copy one into a workflow.
- Constraints carry the rules no writer is trusted with: partial unique indexes, the deferrable
  one-active exclusion, `matches_status_shape`.
- **Grants are the boundary with Kalam.** `kalam` and `runner_gate` get SELECT on a few tables and
  UPDATE on named columns. The gate's match statements run as `runner_gate` over `soma-runner-db`,
  and the admin routes and the token exchange run on `soma-db`. A runner statement that needs a new
  grant is argued on the grant block, and `kalam` is never widened.
- A season's `weight_classes` are validated strictly ascending, because admission takes the first
  class a size fits, and no cap above 64 MiB, because every node's `max_artifact_bytes` refuses a
  larger artifact first. Never reintroduce a class table in a workflow, the generator or config.
- **Season rule ceilings are what a node can honour.** `execution.max_turns` stops at 1000 (Kalam's
  match loop is 1010 sweeps) and `execution.turn_ms` at 60000 (every template's
  `models.max_timeout_ms`). web's `configs.sh` reads both bounds out of the migration; raise one
  only with the thing it protects.
- Every placeholder is cast explicitly, `($n)::type`.
- **Never hand-transcribe a statement into `scripts/verify/`.** Copy it from the shipped workflow.
  `run.sh` compares the flattened text and refuses to run on a difference.
- A negative fixture must reach the predicate it names: stage the row into the state the statement
  requires, and keep a positive case beside it.

### Runner gate

- The match statements' home is `workflows/soma-runner-*.json`. Kalam's `gen-kalam.py` holds
  db-mode copies that **no check compares**, so change both together.
- A gate route's `data.req.*` field names are the contract with the runner. Diff them against the
  body `kalam/scripts/gen-kalam.py` sends.
- `live_runners` is joined **inside** every statement. A JSONLogic guard fails open.
- `finish` writes, then reads back under the same token: `200 {applied: false}` is a duplicate
  delivery, and `409` is a lost claim. Never conflate them.
- **`auth.source.scheme` is a literal prefix and the trailing space belongs to it** (`"Bearer "`).
  Without it every runner gets a bare 401 and every offline gate passes, so
  `check-auth-scheme.py` enforces it. An auth route's smoke coverage needs one round trip that gets
  a 2xx, because a refusal only proves the channel loaded.

### Policy

- File Orion issues generically ("a ranked ladder running competitor-submitted ONNX models"), with
  no repository, path or game of this platform's.
- To learn what an Orion tag contains, read `git log vX..vY` in the Orion checkout, not the release
  notes: fixes have shipped with no changelog entry.
- Commit straight to `main`, with an imperative subject that describes the behaviour change.

## Gotchas

### Orion

- `db_write` returns `rows_affected` and nothing else, so no `RETURNING` reaches the workflow. Each
  task is one statement in its own transaction. Data-modifying CTEs are allowed in `db_write` and
  refused in `db_read`.
- `params` elements fold `{"var": ...}` and nothing else. A `??` or `cat` inline is passed through as
  a literal object, so compute it in a `map` first (`lint` reports `logic.unresolvable`).
- **`${...}` is substituted in instance-template comments too**, before parsing. Only `${X}` and
  `${X:-default}` work (`${X:?msg}` is refused). A mention in a comment makes the variable required,
  which is why `soma.toml.tmpl` needs `R2_ENDPOINT` at parse. Describe forms in words.
- A connector resolves `env://NAME` only when it is the whole string, hence `ORION_ADMIN_BEARER`
  (`Bearer <key>`). `allow_private_urls` and connector URLs are checked by the offline gates before
  `var://` resolves, and a cache connector's `url` cannot be `env://`, so `load-package.sh` writes
  them into a staged copy.
- Every admin API reply is wrapped in `{"data": ...}`. Reading around it yields null, and
  `null != "passed"` is true.
- `channel_call` **ignores** an unknown input key (the payload field is `data`), and delivers its
  argument as the child's payload, so the child must `parse_json` it first. `clippy` flags the first
  as `correctness.unknown_input_key`.
- dataflow-rs **skips** a mapping whose logic evaluates to null, so a slot "cleared" with `None`
  keeps its old value. Clear with `False`.
- A JSONLogic `reduce` binds `current`/`accumulator` through `val` only (`var` yields null).
  `metadata.vars` is root scope and reads null inside a `map`/`filter` body, and
  `{">=": [0, null]}` is true, so carry values in explicitly.
- `http_call` warns and continues on a 4xx without writing its output. Test whether the output
  exists. datalogic has no regex.
- `engine.ops_budget` crossed inside a **condition** fails closed to false and is only logged. It
  reads as a routing miss.
- Twenty tensor operators are live on every expression surface. A single-key object keyed `shape`,
  `full`, `cast`, `pad`, `crop`, `concat` or `stack` is a call, and the escape is `{"$shape": ...}`.
  `tb-probe`'s `{"length": [{"shape": ...}]}` is meant as a call.
- Archive and delete are not refused for a model an active workflow names by a computed id. Model
  `stats` are written at admission and never recomputed.
- `models.max_timeout_ms` clamps a longer `model_infer` timeout **silently**.
- A cron channel always writes a trace row per occurrence: `errors_only` drops only the result, and
  `tracing.mode = "off"` is upgraded to sync. Only the schedule and `[trace_queue] retention_hours`
  bound the volume. `TraceQueueConfig` denies unknown fields, so a typo there is fatal at boot.
- Turning plugin trust on refuses plugins already stored unsigned. Postgres state survives a
  restart, so the package looks present and does not run. `admin_auth` hides `/health`'s plugin and
  quarantine detail unless the request carries the key.
- Repeated auth failures put a client IP into a 401 backoff. Retest from another address before
  believing a second failure.
- `package apply` adds and updates and never removes, which is why `load-package.sh` retires by tag.
- Two REST channels may share a `route_pattern` when their methods do not overlap.
- `[models]` device `metal` measured 36× slower than `cpu`. Use `cpu`.

### Postgres and the schema

- An array of an enum does not bind as a parameter. `ladders` is derived in SQL.
- CTE sub-statements share one snapshot, so one cannot see another's writes to the same table. That
  is why the reap is its own statement, and why sign-in releases a stale handle in a statement of its
  own before its upsert.
- **A data-modifying CTE runs to completion even when nothing uses its output.** Guard the first
  write (count's length guard on the mark, the pass's live-season guard) rather than the outer
  statement.
- `forbid` means non-overlapping, not exactly-once: a node that loses its lease cannot recall a
  statement in flight. That is why every write is fenced.
- **`ratings.matches_played` is the `rating_events` seq.** Resetting it makes count fail every fold
  on the primary key and keep failing. Anything restoring a rating row must set it to at least
  `max(seq)`.
- `PREPARE` (what `check-sql.sh` does, as the owner) never checks privileges. `EXPLAIN` does
  without executing: `SET ROLE runner_gate; EXPLAIN ...` proves a gate statement's grants.
- A bare `ON CONFLICT` is refused on a table with a deferrable constraint, so name the arbiter.
- A JSON number with a decimal part will not bind to an int8 placeholder. Cast `($n)::float8::bigint`.
- `{"<": [x, null]}` is falsy, so a missing ceiling passes every gate unless the null is guarded.
- `psql -c` does not expand `:'var'` (use a script on stdin), and `$(psql ... RETURNING ...)`
  captures the command tag too (use `-At -c "SELECT ..."`).
