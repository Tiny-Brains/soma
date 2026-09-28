# CLAUDE.md

Soma is an Orion 1.11.1 package plus the Postgres migrations every TinyBrains package shares, shipped
as the node image `ghcr.io/tiny-brains/soma`. There is no server code. Behaviour is JSON channel and
workflow definitions whose statements live in `sql/*.sql`, connectors and two
Rust/wasm plugins, so `orion-server lint`/`clippy`/`sql check` act as the compiler. The set declares
the Orion it needs in `shared/package.json`, and every offline command checks the binary against it.
**The package ships two plugins and the node loads three**: `tb.ants` comes from the ants release
the image is built against, and `soma-user-maps-add`/`-update` call `tb.ants.worldgen` to judge a
board — so a map route names a function nothing in this repo builds.

`README.md` is the human guide: routes, clocks, configuration, operating a season, production requirements, invariants and
known gaps. The parent `tinybrains/CLAUDE.md` holds the contracts that cross into kalam, ants, web and
the cli. When you close a gap or find one, update README's **Known gaps**.

## Checks

```sh
./scripts/check-defs.sh                          # every change: clippy, fmt, names/tags/var://, the offline cases, clippy -c; no stack
./scripts/check-tests.sh                         # the offline cases alone (check-defs.sh runs it too); no database, no stack
cargo test --manifest-path plugins/Cargo.toml    # after touching plugins/ (clippy there is clean; the allows are deliberate)
./scripts/check-sql.sh                           # after any SQL or schema change; starts its own postgres
./scripts/verify/run.sh                          # after a gate, clock, notification or schema change; needs a postgres container (DB_CONTAINER)
./scripts/smoke.sh                               # against a running stack with the package loaded
docker run --rm --entrypoint orion-server ghcr.io/tiny-brains/soma clippy /pkg/soma --deny-warnings
```

- **`verify/run.sh` exits 0 through a scenario error.** Read the output, not the exit code. Many
  `ERROR` lines are deliberate negative fixtures, so diff against a run from a `git archive HEAD`
  copy to tell a new error from an old one.
- `check-sql.sh` names the file, connector and role behind every finding, and starts a throwaway
  postgres when `SQLCHECK_DATABASE` does not name one — so it needs no stack. `verify/run.sh` and
  `smoke.sh` still do. `smoke.sh` has no filter: curl the one route instead. Script env:
  `SQLCHECK_DATABASE`, `DB_CONTAINER`, `DB_USER`, `BASE`, `SMOKE_HANDLE`, `SOMA_ENV_FILE`.
- **Which `orion-server` is declared, not tested.** `shared/package.json` carries
  `requires.orion`, and `lint`, `clippy`, `fmt` and `compile` each check the running binary against
  it first, with one line naming both — so no script here has a version test, and `compile` writes
  the range into the artifact for `apply` to check the node against. The pinned source of truth is
  the Orion checkout at `~/Development/Plasmatic/Orion-Projects/Orion`, not the local binary.
- A plugin's digest moves only when its source does. When it moves, web's
  `scripts/setup/sign-plugins.sh` must run again, or `[packages] apply` stops the node on a
  quarantined channel — which is the point: it will not serve the site without its plugins.
- **`scripts/cutover/` is a release's one-time database migration, not a check**, and the order is
  the whole of it: `cutover.sh` (the schema, in one transaction, the old one kept as `legacy`, with
  every node stopped), then `retire.sh` against Orion's state **before the new node boots**, then
  `backfill-frames.sh` once it serves. `retire.sh` cannot wait for `load-package.sh --prune`: a
  release that RENAMES a channel onto a route an active one still claims stops the new node's boot
  apply, and once a boot apply has succeeded the receipt's current version is already the new one,
  so `--prune` then finds nothing. Both scripts dry-run without `--commit`.

## Rules

### Routes

- A route is `channels/soma-<name>.json` + `workflows/soma-<name>.json`. The channel declares
  transport: method, `route_pattern`, `auth`, `rate_limit` (keyed on the address, before auth),
  `principal_rate_limit` (keyed on `auth.sub`, after) and `response.mode: "shaped"`. The workflow is
  a flat task list whose last `map` writes `data.body` and `data._orion.response`.
- Constants and fragments live in `shared/soma.json`, referenced with `$from`/`use`/`$use`: `refuse`,
  `deny-revoked`, `admin-only` (a platform admin's route), `season-admin-only` (a season's route),
  `require-claim-token` (every fenced gate route), `invalidate`, `bump` and `generation` (the cache
  generations), `too-long` and `not-bool` (a refusal on a field's length or shape), `season-not-closed`,
  `sign-uploads` (the two presigned PUTs a submission and a baseline upload share), `notify-comments`,
  the answers several routes end on (`match-answer`, `season-runner-keys-answer`,
  `submission-refusals`), and the value `none_written` (the zero-rows condition every
  refuse-after-write tests). A refusal
  shape that appears twice is a fragment, since clippy's duplication rules see only exact copies. So the set must be **compiled** before it is applied, which `load-package.sh` does.
- **A season-scoped route is a season admin's, not a platform admin's.** `season-admin-only`
  (with the `season_admin_identity` constant) resolves a platform admin OR a live `season_admins`
  member from the route's `{game}`/`{slug}`, off the row on every call, so a removal takes effect at
  the next request. `admin-only` is now the narrower case: creating a season, featuring one, the
  fleet policy, rounds, the fill, and assigning season admins. Both surfaces still tag `admin`.
- **Every season-scoped public read has a `/v1/private/...` twin, and the two share one statement.**
  `channels/soma-user-private-*.json` sits beside `channels/soma-pub-*.json` (fourteen pairs) and
  both workflows name the same `sql/soma-pub-shared-*.sql`: the same SQL with the session's claims,
  so `season_visible()` decides what a private season answers and to whom. A change to a public
  season read is a change to both channels and one file. The private twin declares no `cache` — its
  answer is the caller's.
- **A workflow's `description` is where a route's reasoning lives.** Read it before changing the
  route. Orion refuses one over 2048 characters, and `check-sql.sh` fails first.
- **SQL builds the response and the workflow moves it**: queries end `json_build_object(...) AS
  body`. Shaping a response in JSONLogic is the exception.
- **The session guard is a JOIN on `live_sessions` inside the query**, never a guard task, and the
  JOIN stays inside every signed-in statement as the fence. **`/v1/me` alone is served from the
  session entry in Redis**: `sess:<sid>` on `soma-cache` holds what the route answers, kept five
  minutes (`session_cache_ttl_secs`) under `gen:sess:<user>`, and a hit is an entry carrying the
  current generation whose session has not expired; its miss path is the JOIN, and only a miss
  stamps `last_seen_at` and rewrites the entry (zero when none exists yet). Sign-out deletes the
  entry; sign-out-everywhere, a role change, the commenting switch and a profile edit bump the
  generation with `bump` in its hard form (`soft: false`): a revocation Redis did not record fails
  the request. `candidates` are their own route, because the admit clock moves them and cannot name
  the user. Admin routes read `role` off the live row, never off a cookie claim, so a demotion
  takes effect at once.
  Where `json_agg` without `GROUP BY` would return a row regardless (`soma-user-models-list`, the
  preflight), `live_sessions` is the outer `FROM`.
- **Write, then diagnose.** `db_write` answers only `rows_affected`, so a refusal is one statement
  that does the work, a conditional `db_read` that asks why nothing happened, and a terminal map that
  turns that into an error code (`soma-admin-seasons-create`: `create` → `why` → `refused`).
- **Every admin write inserts its `audit_log` line in the same statement**, as a data-modifying
  CTE over the write's `RETURNING`, so the action and its record cannot disagree.
- A route that can return something private gets its **own path** (`/v1/me/matches`), never a
  parameter on a public route.
- **Only a caller-invariant route may declare `cache`, and it declares `cache.namespaces`.** The
  response-cache key carries method, path params and query, and nothing about the caller. The
  namespaces are drawn from `season`, `ladder`, `matches`, `community` and `announcements`, one or
  more per route, named beside the `$from` constant (`hot_cache`, `season_cache`; both coalesce
  misses). **A writer of public data follows its write with `use: invalidate`** (`shared/soma.json`),
  AFTER the write and only when it moved rows (`when` on the write's `rows_affected`), and inside
  the group that already carries that condition where one exists, or clippy's
  `perf.redundant_step_condition` fails the set. The bump is `continue_on_error`: the write has
  committed, and the channel's TTL is the ceiling on a store the bump could not reach. A new
  cached route names its namespaces; a new writer bumps them; a new namespace is a change to both.
- **Every definition carries three tags, `[package, surface, domain]`**, in that order --
  `["soma", "gate", "matches"]`. `?tag=` is an EXACT, SINGLE-TAG match with no prefix and no AND,
  and no list page searches names or ids, so the tag filter is the navigation and each tag has to
  be a useful question on its own. The surface is one of `pub`, `user`, `admin`, `gate`, `clock`
  (`conn` on a connector) and is also the id's second segment; `scripts/check-names.sh` DERIVES it
  from the definition and fails if the two disagree. The domain comes from a closed list
  shared with kalam -- web's `scripts/check/configs.sh` compares them.
- A node's boot apply
  ADDS and UPDATES only: retiring what a version dropped is `scripts/load-package.sh --prune`, which
  reads the receipt's own inventory rather than sweeping by tag, and is a deliberate operator step
  because it removes routes. So a release that drops a channel needs that one run against the
  cluster; until it happens the old route is still served.
- `/v1/admin-check`'s 204/401/403 and its missing body are a contract with nginx `auth_request`.
- No route hard-codes a callback host or the cookie's Secure policy: `app_url`,
  `oauth_redirect_uri` and `cookie_secure` are deployment `[vars]`.

### Clocks

- **The clocks are AUTHORED, like every route.** `channels/soma-clock-*.json`,
  `workflows/soma-clock-*-run.json` and the `sql/soma-clock-*.sql` they name are edited directly;
  there is no generator and nothing to regenerate.
  A statement keeps the comments and alignment it is written with — Orion's `$sql` normal form
  collapses both when `compile` inlines the file, so a comment costs nothing and a comment edit
  moves neither the statement nor the package's content hash.
- **A statement's file is named from the task that ships it**: `sql/<workflow_id>-<task_id>.sql`.
  A statement two or more tasks share is ONE file carrying `-shared-` instead
  (`sql/soma-pub-shared-matches-list.sql`). `check-names.sh` fails all four ways: a `-shared-` file
  only one task names, a plain file two tasks name, a file on disk nothing names, and a name no file
  backs. A fragment in `shared/soma.json` may ship a statement too (`notify-comments`), and its
  `$sql` counts once per use site, which is what lets a shared statement live in a fragment.
- **A run of tasks that differ only by an index is `$each`, not a copy.** `{"$each": {"n": {"$from":
  "constants.<list>"}}, "do": …}` writes the element once; `{{n}}` interpolates into a string and
  `{"$param": "n"}` inserts it typed. A repeated condition or shape is a value fragment in
  `shared/soma.json`, spliced with `{"$use": …, "with": {…}}`. None of it reaches the server:
  `compile` expands it all.
- Consecutive tasks sharing a condition are written as one task group. **Anything that walks a
  clock workflow must descend into groups**, or it silently skips most of the statements.
- **Soma runs no model.** `[models]` is off. `soma-clock-admit` prepares a submission (HEAD, manifest,
  rebuilt registration) and queues an `admissions` row; an admitting kalam runner claims it through
  `/v1/runner/admissions/*`, runs Orion's admission and the probe, and reports; the clock judges the
  report. A new admission step that needs a model belongs on the runner, and its verdict here.
- The loop shape: `loop.setup` runs once (the fence or the token, the batch read, the halt that
  ends an empty run), `over` is the batch's items and `as: "it"` the item in hand, `scratch: "s"`
  is emptied by the engine before every sweep so every per-item slot lives under `temp_data.s.*`
  and nothing of one item can reach the next, and `max` is a bound, never the terminator: an
  empty batch runs no sweep, and a halting `filter` (`fenced`, `boards`, `held`) ends the run.
  Anything that walks a clock (`scripts/verify/run.sh`, `scripts/check-names.sh`) walks
  `loop.setup` first.
- **Seasons overlap, so every clock is a sweep over seasons and never over "the" season.** A game
  runs any number of live seasons at once. Pair rotates its pick among tied seasons, so a settled
  season cannot starve another, and stamps each match's round; count starts each round that is due
  (the reset, and the old round's queue cancelled `ROUND_ENDED`) before it folds; withdraw keeps a
  season played in rounds one reset ahead, posts each round's countdown, and closes each live season
  whose finals are done. A new clock read that names one season is a bug the local stack's single
  season hides.
- **Demand is the round's, not the ladder's.** Pair reads a round's quota, else the settling rule,
  plus the idle fill (`PATCH .../fill`) into lanes no season is asking for. The fill is what keeps a
  runner busy between rounds, so a change to pair's demand read is a change to both paths.
- **Correctness rests on SQL fences, never on the singleton.** Count claims a run fence on
  `clocks.count` and every ladder write re-reads it `FOR SHARE`. Pair checks the roster epoch in
  every insert. Admission writes only under its row's `admit_token`. Withdraw is idempotent. Anything
  that changes who contests (promotion, rejection, a close, a baseline flip, an engine patch) bumps
  `clocks.epoch` where `key = 'roster'`.
- **Reap and count skip a tick from the cache, never a decision.** Each starts with one soft
  `cache_read` of its generation and its own marker on `soma-cache` (`gen:work` and `idle:reap`;
  `gen:finished` and `idle:count`) and halts, before any fence, when the marker is present and equal
  to the generation; a Redis that cannot answer runs the clock. The marker is written only when the
  tick found nothing (reap: nothing claimed or running, by the `in_flight` read; count: an empty
  batch), under the generation read at the top, with a 60 s TTL, so every clock still runs once a
  minute whatever Redis says. **A generation that does not exist yet is zero**: the `generation`
  fragment follows every probe and reads a missing key as 0, and the first bump (an INCR on a
  missing key) makes it 1, so a marker or entry written under zero is stale the moment anything
  happens. Without that rule a fresh or flushed Redis switches every idle path off until the first
  event, and a fresh node polls Postgres on every claim and every count tick. **Generations move in
  the run that made the work, after its write and only when rows moved, through the `bump`
  fragment:** `gen:work` on pair's insert, the gate's claim and release, and the reap;
  `gen:finished` on the gate's finish and release, the reap, and withdraw's sweep and close;
  `gen:admissions` on admit's queue and requeue. A generation carries no TTL (the cache Redis runs
  volatile-lru); a marker never outlives one. Admit and pair keep their ticks: admit cannot tell
  "nothing waiting" from "waiting but leased" without a read, and pair's demand moves with time.
- **Three Orion features are left off where they would do harm.** Channel `dedup` ships on the four
  admin creates that must not double-fire (`runner-keys-create`, `posts-create`, `notify-send`,
  `announcements-create`, through the `dedup` constant) and is kept OFF the gate's `finish` and the
  admission report: there a replayed key would answer 409, the opposite of the `applied: false`
  read-back those routes give a duplicate. The `validation` function for refusals: it cannot
  choose 404, 409 or 422, and every refusal here is the `refuse` fragment with its own status.
  Response caching of a signed-in route through `key_logic`: a hit would skip the session JOIN
  that is the fence, so `/v1/me` is served from its own session entry instead (above).
- **Only count writes a ladder**, and no clock deletes (`soma-db` sets `operations.delete = false`).
  That a clock never reads `sessions` or rewrites an entry is enforced by review, not by a grant.
- `tb.pairing` decides quality, never correctness. It must stay pure and seeded by the occurrence
  id, and every correctness rule (seat count from the board, contesting, self-pairing) is repeated
  in pair's `insert`. Trials are picked in SQL (pair's `trials`), not by the plugin. `tb.rating` refuses a
  missing parameter rather than defaulting one, and its output is the fold's `$4` exactly.
- **Admission branches on whose fault it is, not on the reason word**, and `admission_facts()` in
  the migration is where that is decided for a report: a `failed` stage of `size`, `digest`, `parse`
  or `probe` is the competitor's and rejects; `gate`, `head`, `fetch`, `cache`, a timeout and a probe
  over `max_probe_ms` are the runner's (`again`: back to the queue, attempt spent). A probe over it on
  EVERY attempt is the model's after all: `expire` counts them (`admissions.slow_probes`) and rejects
  `PROBE_TOO_SLOW` instead of `TIMED_OUT`. A fault of the
  clock's own (`retry`) releases the item and spends nothing, so every "ours" that can recur for one
  submission is a retry every tick for ever -- a new branch into `retry` needs a reason it cannot be
  the submission, and a new runner fault goes to `again`, which runs out.
- **A runner's report is read only through `admission_facts()`**, which types every value. The
  batch read binds parts of it, and a cast error there stops admission for everyone behind it.
- **An attempt is a runner's claim** (`admissions.attempts`). A submission waiting for a runner
  spends none and never expires, which is why expiry requires the last lease to have lapsed.
- **No large document rides a clock's message.** On a channel with `task_details: true` every
  write keeps deep copies of the old and new value in the audit trail (Orion turns
  `capture_changes` on exactly then), and an errored run keeps its whole trace, so the reference set
  carried per item held ~3 GB for ten submissions. The looping clocks, count and admit, run with
  `loop_clock_tracing` (`task_details: false`) for that reason; pair, reap and withdraw keep the
  per-step detail a failed run is diagnosed by. The batch carries its length; the gate's admission claim
  reads the set straight from `games` for the runner.
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
  no ALTERs and no third file (`check-sql.sh` and `verify/run.sh` name exactly these two).
- **`bootstrap` hashes every byte of the migrations, comments included**, and refuses a database
  with a different digest. Any edit, even a comment, means rebuilding the local database, so never
  touch them for cosmetics.
- A shape several routes return is a function in the migration (`season_json`, `season_state`,
  `current_season`, `model_phase`, `model_ratings`, `ladder_field`, `match_seat_rows`). Never copy
  one into a workflow.
- **Who may see or enter a season is a predicate in the migration, never a WHERE in a workflow**:
  `season_visible` (the public/private twins both call it), `viewable_season`, `season_is_admin`,
  the seven `season_admits*`, and the shape rules a write is validated by (`season_rules_ok`,
  `season_rule_spec`, `season_fleet_ok`, `season_fill_ok`, `season_round_numbers_ok`,
  `weight_classes_ok`). A route that decides visibility for itself is a second policy.
- **`audit_log.season_id` is derived by the trigger `audit_log_season`**, from the row the admin
  write touched. The writer still inserts its audit line in the same statement; which season it
  belongs to is the schema's business, and a writer that sets it by hand can disagree with the row.
- **A text rule is one IMMUTABLE function** (`line_ok`, `site_path_ok`, `link_ok`, `slug_ok`,
  `comment_word_ok`) that the table's CHECK, the write's WHERE and its `why` all call. Never restate
  one as a literal predicate: a write and its diagnosis then disagree about why a request failed.
- **`threads.comments` is kept by the trigger `comments_count_live`**, on every INSERT or UPDATE OF
  `state` on `comments`. A writer never adjusts it by hand, or the count moves twice.
- Constraints carry the rules no writer is trusted with: partial unique indexes, the deferrable
  one-active exclusion, `matches_status_shape`.
- **Grants are the boundary with Kalam.** `runner_gate` gets SELECT on a few tables and UPDATE on
  named columns. The gate's match statements and the reap clock run as `runner_gate` over
  `soma-db-gate`, and the admin routes and the token exchange run on `soma-db`. A runner statement
  that needs a new grant is argued on the grant block, never by widening the role.
- A season's `weight_classes` are validated strictly ascending, because admission takes the first
  class a size fits, and no cap above 64 MiB, because every node's `max_artifact_bytes` refuses a
  larger artifact first. Never reintroduce a class table in a workflow or in config.
- **A class's memory numbers are ceilings a runner must carry.** `weight_classes_ok()` bounds
  `memory_flat_bytes` at 262,144 and `memory_cell_bytes` at 16, and web's `configs.sh` reads both
  out of it (the `BETWEEN 0 AND <n>` on the key's own line) to check them against kalam's
  `max_input_elements` and `max_output_elements`; raise one only with the runner's template.
  Routes return a season's classes through `weight_classes_public()`, which fills an absent number
  with 0.
- **`memory_price()` is the only memory rule.** The admit clock's `classify` calls it for the class
  the size lands in, and a backfill or a `why` calls it too, never a copy. Its three verdicts are
  final and the competitor's; no verdict and no bytes where the class allows memory is a game with
  no `limits.boards`, which `judge` retries as `BOARDS_UNDECLARED`. `probe.round_trip`'s keys
  (`checked`, `failed`) are a contract with kalam-admit's report, typed in `admission_facts()`
  beside the others as `round_trip_refused`.
- **Season rule ceilings are what a node can honour.** `execution.max_turns` stops at 1000 (Kalam's
  match loop is 1010 sweeps) and `execution.turn_ms` at 60000 (every template's
  `models.max_timeout_ms`). web's `configs.sh` reads both bounds out of the migration; raise one
  only with the thing it protects.
- Every placeholder is cast explicitly, `($n)::type`.
- **Never transcribe a shipped statement into `scripts/verify/`.** `run.sh` READS each one out of
  the workflow that ships it -- through its `$sql` file -- and emits the `PREPARE` itself, so the
  harness walks what ships by construction. `statements.sql` holds only what NOTHING ships: the
  harness-only variants and reads. Adding a shipped statement back is refused by name. A statement
  listed against several tasks (`n_version` ships from three) asserts they are the same statement.
- A negative fixture must reach the predicate it names: stage the row into the state the statement
  requires, and keep a positive case beside it.

### Tests

- **Every route and clock has offline cases**, `tests/<name>.case.json`, run by `orion-server test
  tests --definitions .`. No database and no stack: a case names its `workflow`, its `metadata`
  (`auth.claims`, `params`, `vars`), and **stubs one value per connector per task type** — so a case
  shapes the one row that has to satisfy every read on the branch it walks.
- What a case asserts is the branch, not just the answer: `expect` (dotted paths into `data`),
  `expect_calls` (an EMPTY list is the assertion — that the branch made no `db_read`, no
  `cache_write`), and `expect_tasks`, the path through the workflow. A cached route's case is worth
  more than its answer: it proves the statement did not run.
- **The set carries its own two plugins**, so `tb.rating` and `tb.pairing` run for real. Naming
  either again with `--plugin-dir` declares it twice and is refused.
- **`tests/with-ants/` is a second run.** Those cases name `tb.ants`, which this package does not
  ship, so they need its directory: `TB_ANTS_PLUGIN_DIR`, else `../kalam/plugins/tb-ants`, else
  `../ants/dist`. `test` does not recurse, so the main run never sees them, and with no plugin they
  are skipped and say so — a skip reads like a pass in CI on a machine with no sibling checkout.
- A case runs at a node's cost (no trace, no capture), so a clock's whole loop is affordable: cover
  the halt, the fence lost, and the sweep, not only the happy path.

### Runner gate

- The match statements' home is `workflows/soma-gate-*.json`, and there is **one copy**: Kalam's
  db mode is gone, and with it the second set of statements nothing compared.
  `scripts/verify/run.sh` reads each statement out of the workflow that ships it, so the harness
  cannot drift from what is served either.
- A gate route's `data.req.*` field names are the contract with the runner. Diff them against the
  body `kalam/workflows/kalam-match-run.json` sends.
- `live_runners` is joined **inside** every statement. A JSONLogic guard fails open.
- **A row goes only to a runner that can finish it.** The claim's `pick` prices the row with
  `match_execution()` (the one function `row` sends as the contract) against the runner's reported
  `match_timeout_ms` and `seat_concurrency`: turn_ms × max_turns × the seat batches, plus a tenth.
  A row no runner can hold stays pending and visible; a runner that reported neither is unbounded.
- **The idle claim is answered from the cache, per runner.** `claim` reads `gen:work` and
  `idle:<engine digest>:<runner>` in one `MGET` before the statement and answers `{"idle": true}`
  when the marker is present and equal to the generation; a claim that moved no row stores the
  generation it read under that marker (`idle_marker_ttl_secs`), zero when none exists yet. The
  marker is the runner's own, because an empty answer may be its own (at its in-flight ceiling, or
  refused a row by the fit), and its `finish` deletes it so a freed slot re-checks at once. A claim
  that took a row bumps `gen:work`, since an in-flight row is one the reap must see. The admission
  claim is the same shape under `gen:admissions` and `idle:admissions:<runner>`, with one
  difference: a lapsed lease makes a row claimable again with no write, so its marker is written
  only when no admission waits at all, leased or not, which one `EXISTS` read (`waiting`) decides
  after a claim that moved nothing.
- `finish` writes, then reads back under the same token: `200 {applied: false}` is a duplicate
  delivery, and `409` is a lost claim. Never conflate them.
- **`auth.source.scheme` is a scheme NAME, parsed as RFC 9110 defines it.** `"Bearer"` and
  `"Bearer "` are the same scheme, the comparison is case-insensitive, and any run of spaces
  separates it from the credential — so the trailing space no longer decides whether every runner
  gets a bare 401, and the check that enforced it is gone. A value that is not a token (`"Key="`,
  `"Bearer:"`) is refused at create, by `lint`, and by `preflight`'s `channel-auth`. An auth route's
  smoke coverage still needs one round trip that gets a 2xx, because a refusal only proves the
  channel loaded.

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
- **`${...}` in an instance template takes three forms and skips comments.** `${X}`, `${X:-default}`
  and `${X:?message}` (which stops the boot with that sentence, and the file, line and column, when X
  is unset OR empty); a default or a message may nest another placeholder. The file's `#` comments
  are NOT substituted, so a form may be written out in prose without making its variable required —
  which is why `soma.toml.tmpl` no longer needs `R2_ENDPOINT` at parse. Anything else (`${X:+y}`,
  `${X-y}`) is refused by name.
- A connector resolves `env://NAME` only when it is the whole string, hence `ORION_ADMIN_BEARER`
  (`Bearer <key>`); `lint` warns (`env.embedded_reference`) on a reference inside a longer string.
  An http or cache `url` MAY be `env://` and any connector boolean may be a reference
  (`allow_private_urls` is `var://allow_private_urls`, from `[vars]`), so nothing stages a copy of
  the set any more — the deployment's settings are declarations in the committed connectors.
- **A NUMBER IS A `var://`, NEVER AN `env://`.** `var://` substitution is TYPED — the var keeps the
  type `[vars]` declared it with — while `env://` always resolves to a string, and the only coercion
  at a reference site is `true`/`false`. So `"max_connections": "env://X"` fails at load naming the
  field, and `"var://db_max_connections"` works. **Every pool size, rate limit and cache TTL in this
  package is a var**: the two db pools, `[storage]`'s, `[cron] workers`, the nine rate families in
  `shared/soma.json` and the two cache TTLs, each `${SOMA_...:-default}` in `soma.toml.tmpl` and
  nowhere else — a compose file passes `${NAME:-}` and `entrypoint.sh` turns empty back into unset,
  so the default has one home. `soma-admin-check`'s 100/200 stays a literal on purpose: it is the
  guard that stops nginx's `auth_request` locking an admin out, not a budget.
  **Orion's `[vars]` clippy rule does not read a connector's or a channel's config**, only workflow
  logic, so a renamed var there passes `clippy -c` and stops the node at its boot apply instead;
  `scripts/check-names.sh` is what refuses it offline.
- **An `env://` that resolves to an empty string is now REFUSED, not accepted.** A connector's
  endpoint is scheme-checked again AFTER its references resolve, so `""` fails as `ftp://` would,
  the connector is skipped, and a workflow naming it cannot activate. Setting a variable empty to
  "switch a connector off" no longer works: give it a well-formed URL that routes nowhere.
- Every admin API reply is wrapped in `{"data": ...}`. Reading around it yields null, and
  `null != "passed"` is true.
- `channel_call` **ignores** an unknown input key (the payload field is `data`), and delivers its
  argument as the child's payload, so the child must `parse_json` it first. `clippy` flags the first
  as `correctness.unknown_input_key`.
- dataflow-rs **skips** a mapping whose logic evaluates to null, so a slot "cleared" with `None`
  keeps its old value. Clear with `{"path": …, "unset": true}`, which removes it.
- A JSONLogic `reduce` binds `current`/`accumulator` through `val` only (`var` yields null).
  `metadata.vars` is root scope and reads null inside a `map`/`filter` body, and
  `{">=": [0, null]}` is true, so carry values in explicitly.
- **An HTTP non-2xx is a task error**, not an answer: the task fails and the run halts unless the
  task is `continue_on_error`, in which case it carries on with the output unwritten. Test whether
  the output exists. datalogic has no regex.
- `engine.ops_budget` crossed inside a **condition** fails closed to false and is only logged. It
  reads as a routing miss.
- Twenty tensor operators are live on every expression surface. A single-key object keyed `shape`,
  `full`, `cast`, `pad`, `crop`, `concat` or `stack` is a call, and the escape is `{"$shape": ...}`.
  A data key of one of those names is read as an operator wherever an expression touches it; a TASK
  named `shape` (admit's registration rebuild) is not an expression and is unaffected.
- Archive and delete are not refused for a model an active workflow names by a computed id. Model
  `stats` are written at admission and never recomputed.
- **Orion activates only a `draft` version.** An archived model 404s on `status: active` and 409s on
  a second `register`, so it cannot be walked again. A delete answers 204 with no body, which
  `http_call`'s default `json` fails to parse: set `response_format: "text"`.
- **`storage_head` answers a missing object with `{"exists": false}`**, not a failure, and an object
  is truthy. Test `.exists`.
- **`channel_call` fails whole on any error the child recorded**, `continue_on_error` tasks
  included, and writes no output. A child cannot report a failed step as its answer.
- orion-server allocates through glibc, whose per-thread arenas keep freed memory: the image sets
  `MALLOC_ARENA_MAX=2`, which took an idle node from ~910 MB to ~70 MB.
- `models.max_timeout_ms` clamps a longer `model_infer` timeout **silently**.
- **Only a failed run keeps a trace**: `[trace_storage] errors_only = true` is the default for every
  route, and the gate's poll routes carry `task_details: false`, so a hot route never builds one.
- A cron channel always writes a trace row per occurrence: `errors_only` drops only the result, and
  `tracing.mode = "off"` is upgraded to sync. Only the schedule and `[trace_queue] retention_hours`
  bound the volume. `TraceQueueConfig` denies unknown fields, so a typo there is fatal at boot.
- Turning plugin trust on refuses plugins already stored unsigned. Postgres state survives a
  restart, so the package looks present and does not run. `admin_auth` hides `/health`'s plugin and
  quarantine detail unless the request carries the key.
- Repeated auth failures put a client IP into a 401 backoff. Retest from another address before
  believing a second failure.
- `package apply` adds and updates and never removes; `--prune` removes what the applied version
  carried and this artifact does not, from the receipt's inventory. The boot apply does NOT prune.
- **`package apply` now FAILS when the reload quarantines what it carries**, naming each member,
  before the receipt flips — so "applied" means "serving". Re-applying the version a node already
  runs is checked the same way rather than reported as nothing to do.
- Two REST channels may share a `route_pattern` when their methods do not overlap.
- `[models]` device `metal` measured 36× slower than `cpu`. Use `cpu`.
- **A namespace counter (`orion:rc:ns:<name>`) has no TTL, and a missing one reads as version 0.**
  Under `allkeys-lru` Redis can evict it, and an entry stored before the first bump is then served
  again. The cache Redis runs `volatile-lru` (web's production compose), so eviction takes entries
  and never a counter. `cache_invalidate` takes no connector: it bumps the cluster Redis, every
  in-memory store on the node and every Redis cache connector, and fails only after every
  reachable store is bumped.

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
- `PREPARE` never checks privileges; `EXPLAIN` does, without executing. `orion-server sql check`
  is built on exactly that — it prepares each statement as its connector's role and, on PostgreSQL
  16+, plans it with `EXPLAIN (GENERIC_PLAN)`, which is what proves `runner_gate`'s grants.
  `soma-db` is reported "grants not proven" because it connects as the owner, which holds every
  grant by construction.
- A bare `ON CONFLICT` is refused on a table with a deferrable constraint, so name the arbiter.
- A JSON number with a decimal part will not bind to an int8 placeholder. Cast `($n)::float8::bigint`.
- `{"<": [x, null]}` is falsy, so a missing ceiling passes every gate unless the null is guarded.
- `psql -c` does not expand `:'var'` (use a script on stdin), and `$(psql ... RETURNING ...)`
  captures the command tag too (use `-At -c "SELECT ..."`).
