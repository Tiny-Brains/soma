# Orion — what building TinyBrains found

> **Moved from `devops/docs/` on 17 September 2026**, when devops stopped running anything (N25).
> The page was split by the repository each section is about, and every section keeps the number the
> whole page gave it, so a citation of *§0.3* still resolves — in the repository that section now
> lives in. §0c (a skipped connector fails every workflow that names one) and §2 (the wave workflow) are
> [kalam's](https://github.com/Tiny-Brains/kalam/blob/main/docs/orion-notes.md).
> It was written before N25: where it describes in-cluster Kalam replicas, a loader, an Orion image
> devops built or `docker-compose.fleet.yml`, the platform now runs a Soma node image, runners from
> kalam's compose file, and web's `docker-compose.yml`.

The facts each build turned up that no design document had written down. Each cost time once; this
file is so that none costs it twice. They belong to no single package, which is why they live here.
§1–§4 were found at 1.7.0 and still hold; §0 was found rebuilding on **1.8.1**, and §0b
wiring the runner gate onto it.

The generator docstrings in [`soma`](https://github.com/Tiny-Brains/soma) (whose clocks were the
`jodi` repository until 16 September 2026) and [`kalam`](https://github.com/Tiny-Brains/kalam) carry
the same facts where they apply. *Jodi* in a finding below means Soma's clocks.

---

## 0. The 1.8.1 rebuild, 14–15 September 2026

Every one of these was found by a thing failing in a way that named something else.

| Finding | What it means |
|---|---|
| **`${VAR}` inside a COMMENT in an instance template is still substituted.** `env_substitute` is textual and runs before any TOML parse, so a comment mentioning `${ORION_VERSION}` makes that variable required — and the node refuses to start with "Required environment variable ... is not set" pointing at the file, not the line | Write the bare name in prose. `scripts/check/configs.sh` catches it by parsing both templates through `orion-server validate-config` |
| **A connector resolves `env://NAME` only when the reference is the ENTIRE string.** `"Bearer env://ORION_ADMIN_KEY"` is a literal, and the node answers `401 Invalid API key` — a message about the key, when the problem is the header | Put the whole header value in one variable: compose sets `ORION_ADMIN_BEARER: Bearer ${ORION_ADMIN_KEY}`. Orion reads `Authorization: Bearer <token>` and nothing else unless `[admin_auth] header` says otherwise |
| **Repeated auth failures put a client IP in a backoff**, and every later request from it is refused with the same 401 whatever the credential | A clock failing on a bad header makes the node look broken to `curl` from inside the container too. Test from outside, or from a different address, before believing the second failure |
| **Every admin reply is wrapped in `{"data": …}`.** A workflow reading `temp_data.reply.status` finds null, and `null != "active"` is TRUE | Read through the envelope: `temp_data.reply.data.status`. This cost two clocks an afternoon on the same day — the match barrier released every row for ever, and the roster clock re-registered a model it already had |
| **A `storage` connector is SSRF-checked like an `http` one.** A compose service name resolves to a private address, so a model registration fails at the `head` stage naming an internal IP | `allow_private_urls` is a deployment property applied by each `load-package.sh`, not a committed connector field |
| **`db_write` folds `{"var": …}` nodes and nothing else.** A `??` or a `cat` written inline in `params` is written through as a literal object | Compute it in a `map` task first. `lint` reports it as `logic.unresolvable`, which is why the lint runs before the load |
| **Inside NESTED iterators the enclosing element is not addressable.** `{"val": [[1], …]}` reads the innermost element and every higher level reads the root — so a cross product whose inner body needs the outer element is not expressible | Verified, not assumed. It is why the cartridge sends the visibility mask instead of every adapter deriving it (decision R5), and it is what `axon/docs/dialect.md` §3 was right about all along |
| **`{"val": […]}`'s path segments are EVALUATED**, so `{"val": [[1], "data", "dirs", {"var": ""}]}` indexes an array by a computed index | The clean way to map an index onto a name — no `at` operator needed, and the nested-`if` chain it replaces cost four comparisons per element |
| **A tract plan is built from the DECLARED shape, and a graph that computes indices internally needs concrete spatial dims.** A fully-convolutional net takes `["H", "W"]` happily; `drill/models/ragged.onnx` fails `analyse` under symbolic ones and loads at a fixed 64×96 | A competitor's choice, and admission tells them which they made: the refusal is at the parse stage with tract's own message |
| **`stats_output.inference_ms` is a float and `infer_us_total` is a `bigint`.** `jsonb_to_recordset` refuses `10051.542`, and a finish statement then writes nothing with no explanation | Floor once, where milliseconds become microseconds |
| **A cache connector's `operations` gates reach the RESPONSE CACHE, not just `cache_read`/`cache_write` tasks.** `"operations": {"read": false, "write": false}` on a connector no workflow calls still quarantines every channel whose `config.cache` names it | Read the guard and you will not find it: the check is at channel registration, not in `check_response_cache`, which takes the backend straight off the runtime config. The refusal is exact — *"response cache: connector 'soma-cache' has operations.write = false, and response cache writes through it"* — which is the strict-mode quarantine `deployment.md` §14 predicts, doing its job |
| **A cache connector's `url` may not be an `env://` reference.** It is scheme-checked against `redis`/`rediss` (`validation/endpoints.rs`), exactly as an http connector's base is against `http`/`https` | The third connector kind with this trap, after http and the storage endpoint that does not have it. `soma/scripts/load-package.sh` substitutes `SOMA_CACHE_REDIS_URL` into the committed literal at load, and sets `allow_private_urls` unconditionally — a cache is private wherever it runs |
| **The default response-cache key already carries the route.** `compute_cache_key` feeds `http_method`, `metadata.params` and `metadata.query` before it ever looks at the payload, each length-prefixed, SHA-256 truncated to 128 bits | So an anonymous REST GET needs no `cache_key_fields` and no `key_logic`: `/v1/profiles/{a}` and `/v1/profiles/{b}` cannot collide. What the key does NOT carry is the caller — no cookie, no claim — so **caching an authenticated channel serves one session's body to the next**, and only caller-invariant routes may declare `cache` |
| **MinIO's Docker Hub repository is gone.** `minio/minio` answers "pull access denied … repository does not exist" for every tag including `latest`, as of 14 September 2026 | `quay.io/minio/minio` serves the same tags. Not an Orion fact, but it stops a fresh stack dead |

### 0.1 `engine.ops_budget` — how a refusal surfaces is not uniform

The ceiling is **per evaluation**, not per task, message or workflow: every adapter gets its own
fresh allowance, and a task evaluating ten expressions gets it ten times. That is why one number —
`1_000_000` on the Kalam node, equal to the game's `adapter_ops_max` — serves both an untrusted
adapter and the workflow's own conditions. `0` installs no ceiling; the counter runs either way, at
a measured +3.6% per op. One operation is one dispatched node, one item an iterator examines, or
whatever an operator charges; literals and constant-folded subtrees cost nothing, a CSE-memoised
subtree is charged once, and `try` can observe `BudgetExceeded` but not recover from it.

| Where the ceiling is crossed | What happens |
|---|---|
| a custom function's template field (`http_call.path`, a model adapter) | task fails `BUDGET_EXCEEDED`, not retried, `400` to a sync caller |
| a built-in `map` mapping | task fails with status `500`, reason to the log |
| a **condition** (workflow, task, group, `filter`) | **fails closed to `false`, logged only** — reads as "no workflow matched", and the caller gets a `200` with their own input back |

That third row is the one to remember: a budget crossed inside a condition is invisible at the call
site and looks like a routing miss.

### 0.2 The models entity — the parts that bite

| Finding | What it means |
|---|---|
| **Twenty tensor operators are live on EVERY expression surface**, not just inside a manifest — conditions, `map` mappings, template fields, channel guards. Seven collide with ordinary JSON keys: `shape`, `full`, `cast`, `pad`, `crop`, `concat`, `stack` | In a template position a single-key object keyed by one of them is a **call**, not data. The escape is `{"$shape": [6, 7]}`. `orion-server preflight` reports each as `logic.tensor_operator_key`, and **this stack expects exactly one** — `tb-probe`'s `{"length": [{"shape": […]}]}`, which is a real call to get the policy tensor's rank. A second id is a finding |
| **Archive and delete are refused while an active workflow names the model by a LITERAL id — and a computed `model` is outside the rule** | `tb-match` passes `{"var": "data.seats.0.model_id"}`, so Orion will not protect the roster from an archive. Whatever keeps a model alive while matches reference it has to be ours; the node will not say no |
| **An adapter may not read `{"secret": …}`, `now` or `random`** — refused at registration, not at run time | The isolation property the ladder rests on: a competitor's expression sees tensors and nothing else, and the graph sees even less |
| **Stored `stats` are written at admission and never recomputed** | A row keeps the numbers the node that admitted it measured. Re-admission is what moves them, so a model sitting just under a ceiling can be refused on a re-admission it passed before |
| **`[models.default_runtime]` device `metal` measured 36× SLOWER per inference** than `cpu` on a small graph | `cpu` is both the default and the recommendation. Do not spend an afternoon on this one |
| **The session cache is keyed by `(digest, runtime, device, binding)`** — the binding being what the load actually reads from the manifest — and admission in a cluster shares the *verdict* but not the bytes: peers load without re-probing, and each fetches and re-hashes the object itself | One artifact under two manifests is safe. A replica still pays its own fetch |
| **`models.preload = "referenced"` warms nothing when the workflow computes its `model`** | Which is exactly what `tb-match` does, so the Kalam node sets `preload_tags = ["ladder"]` beside the mode — a union with it, not a fourth mode |

### 0.3 Every generation recompiles every active model's adapters

`runtime/reload.rs` lists every active model row and compiles its adapter and result expressions on
the generation's engine — at every workflow activation, channel edit, connector change and package
reload. **This is not about to change, and the reason overturns the ask rather than declining it**:
`Engine::with_new_workflows`, the cheap reload path, compiles on a *fresh* datalogic engine too, and
a compiled program belongs to the engine that compiled it. There is no branch where carrying an
unchanged `ModelSet` across would be safe, which is why the fingerprint that would have compared one
never had a caller and was deleted. Do not re-file it; the upstream issue
([#328](https://github.com/GoPlasmatic/Orion/issues/328)) is closed with that reasoning and a unit
test pinning the fact, so the day `with_new_workflows` stops handing back a new engine, Orion's own
build fails.

**It matters more here than upstream, for a topology reason.** Each `kalam-N` is its own Orion with
its own state database (decision 41), so every replica carries the whole roster and pays the
recompile independently. At ten models it is invisible; the number at which it is not is unknown,
and a package reload has never been timed against a staged roster of 10, 100 and 1,000. What we
control meanwhile is how often a generation is built on a
replica — a replica nobody is editing does not rebuild, so this is a deploy-cadence cost and never a
per-match one.

---

## 0b. `auth.source.scheme` is a PREFIX, and the space is part of it

Found on 16 September 2026, wiring the runner gate, and it cost an hour because every symptom
pointed elsewhere.

`auth.mode: "jwt"` with `source: { header: "Authorization", scheme: "Bearer" }` refuses **every**
token with `401 UNAUTHORIZED` and no further detail. The token is well-formed, correctly signed,
unexpired, and carries the right `iss` and `aud`; the same secret mints it one route earlier in the
same node.

The cause is one character. `channel/auth.rs` extracts the token with

```rust
value.strip_prefix(prefix.as_str()).ok_or_else(|| self.refuse(RejectReason::Malformed))?
```

so the configured scheme is stripped **literally**. `"Bearer"` leaves `" eyJ0eXAi…"` with a leading
space, which is not a JWT. Orion's own default is `"Bearer "` **with a trailing space**
(`auth.rs`, the `JwtSource::Header` fallback), which is the tell: the default is the correct value
and a hand-written config is how you lose it.

**What makes it expensive rather than merely annoying:**

- The failure is `401`, the same code as an absent token, an expired one, a wrong audience and a
  revoked key. Every one of those is a plausible first guess and none of them is it.
- It is **invisible to every offline gate**. `lint`, `clippy`, `compile` and `package lint` all pass:
  `"Bearer"` is a valid string in a valid field.
- It is **invisible to a smoke test that only asserts 401**, which is the natural shape for an auth
  route — "an anonymous caller is refused" passes identically whether the route works or not. Soma's
  runner checks did exactly that and were green while no token could ever be accepted.
- Sending `Authorization: Bearer<token>` with **no** space succeeds, which is how it is confirmed in
  one command and also why a hand-rolled client can paper over it for ever.

**The rule:** any channel declaring `auth.source.scheme` writes the trailing space, and any auth
route's smoke coverage carries **one round trip that gets a 2xx** — not only refusals. A refusal
proves the channel loaded; only an acceptance proves it works.

**And it happened again, the same day, from a different direction.** The fix was a working-tree
change that had not been committed; a `git checkout` of that file to undo an unrelated reformat took
it with it. Eleven minutes of a live fleet minting tokens and claiming nothing, and every symptom was
the same as the first time. **A rule that lives only in a document is one edit from being lost**, so
it is a check now — `soma/scripts/check-auth-scheme.py`, run by `check-defs.sh`, which refuses any
auth constant whose scheme is not `rstrip() + " "`. It cost five minutes and would have caught both.

---

## 0d. Smaller ones from the same build

**`${NAME:?message}` is not a form Orion understands.** It accepts `${NAME}` and `${NAME:-default}`
and reports anything else as `Invalid env var name 'NAME:?message'`, quoting the whole string as the
name. Requiredness belongs in the compose file, which has that form and fails before a container is
created rather than sixty seconds into the entrypoint's migrate-retry loop.

**Substitution runs over the file, not over its values.** A `${…}` reference inside a **comment** is
substituted too, and an invalid one there fails the config exactly as a live setting would — so a
comment written to warn the next reader about the form above fails for the reason it is warning
about. Describe such a form in words.

**`models.max_timeout_ms` clamps silently.** `model_infer`'s `timeout_ms` is reduced with
`v.min(config.max_timeout_ms)` (`model/limits.rs`) and nothing is logged or traced. A node whose
ceiling is below what a workflow asks for gives the model less time than the caller believes, and
every layer above reports a normal result. If a per-call deadline is data — from a season, a tenant,
a request — the node's ceiling has to be the largest value that data may hold, and asserted against
wherever that bound is declared.

**A clock's traces cannot be turned off, and `errors_only` means two different things.** The sync
request path calls `should_drop` (`channel/registry.rs:57`) *before* it writes anything, so a REST
channel carrying `errors_only: true` persists **no row at all** for a clean call. A cron channel
cannot: `cron/worker.rs:394` runs the effective config through `for_async_submission()`, which
upgrades `mode = "off"` to `sync` and pins `sample_rate` to 1.0, and `create_pending` then writes the
row *before* the workflow starts so a run that dies mid-flight is visible. `errors_only` there drops
only the **result**, leaving a ~140-byte husk per occurrence — measured on the local stack, that is
exactly what `tb-count`, `tb-pair` and `tb-admit` write. So the only levers on a clock's trace
volume are its schedule and `[trace_queue] retention_hours`; `tracing.mode = "off"` on a cron channel
is silently not what it says.

**Retention is real and it is one knob for two tables.** `[trace_queue] retention_hours` defaults to
**72**, and `bootstrap.rs` hands the same value to both the trace cleanup and `cron::start_cleanup`
— an occurrence and the trace it produced age out together. Left unset, a node keeps three days of
every poll its gate answered. `TraceQueueConfig` is `deny_unknown_fields`, so a mistyped key here is
fatal at boot rather than ignored; `orion-server validate-config -c <tmpl>` prints the effective
value and is the cheap way to check it.

---

## 1. The schema and Jodi (now Soma's clocks)

| Finding | What it means |
|---|---|
| **`[plugins] cache_dir` cannot be set.** It is reserved in 1.7.0 and a *non-empty* value is refused at startup | Early design notes for both packages said "set a `cache_dir`"; they are wrong for this version, and compiled artifacts are held in memory. Both instance configs say so where the key would go |
| **Every task needs a `name`.** A workflow whose tasks carry only `id` is refused at create with `REQUIRED` per task | Jodi's count and pair task lists were written without one. The generated workflows add it; a hand-written one will be refused, which is the good failure |
| **`db_write` returns only `rows_affected`,** as the layers assumed — confirmed by every fenced statement in count and pair halting correctly on zero | The design's core idempotence argument survives contact |
| **A plugin component reaches Orion base64-encoded in a JSON body, not as an argument.** 100 KiB of wasm is ~133 KiB of text, and passing it as an argv entry is "Argument list too long" on any shell | Both load scripts write it to a temp file and use `jq --rawfile` / Python. The manifest is authored as TOML and *generated* as JSON, because the images have `jq` and no TOML parser |
| **`orion-plugin-sdk` is on crates.io at the pinned version.** No path dependency into a sibling checkout is needed | Both plugins build from this repository alone. The SDK is wasm-only in `Cargo.toml`, so the pure logic stays host-testable — which is the only reason the TrueSkill maths could be checked against a reference at all |
| **A schema rewritten in place does not reach a database that already holds the old one** | Under Postgres's `/docker-entrypoint-initdb.d` this was silent -- that directory runs once per db volume and is skipped on an existing one -- and it surfaced as `relation "clocks" does not exist` on every count tick, which looks like a bug in count. `db-bootstrap` records the digest of the migrations it applied as a per-database setting and refuses a mismatch at bring-up, naming `devops/scripts/dev/resync-dev-schema.sh` |
| **Two packages in one orion-server are kept apart by their tag, not by the server.** Each load script sweeps `pkg:soma` or `pkg:jodi` and re-creates only its own; an *active* workflow is immutable, so loading is delete-by-tag then create | This is what made the repo split cost nothing: `jodi/scripts/load-package.sh` deletes nothing of Soma's and Soma's deletes nothing of Jodi's, even loaded into the same server. Sweeping by tag rather than by the files present also means a channel a package stops shipping does not linger active and keep ticking |
| **Plugins load before the workflows that name them, and `allow_private_urls` is a deployment property rather than a package one** | A workflow naming `tb.rating.trueskill` with no plugin behind it is *quarantined* at load — it loads, and then fails on its tick — so the arithmetic has to exist before the clock. Orion's SSRF guard refuses a compose service name or a VPC host unless the connector opts in, so the load script rewrites that flag in rather than the package shipping it. Plugin uploads land as drafts and are activated by a PATCH, exactly as workflows are; Orion compiles and probes the component before writing the draft row, so a `201` has already proved it loads |

## 3. Admission

Orion's `http_call` warns and continues on a `4xx` without
writing its output, and only a `5xx` is an error — so every stage tests whether its output *exists*
rather than reading a status code, and the best-effort GitHub call needs no branch at all.
`temp_data` survives a loop sweep, so every per-item slot must be cleared as the item is taken; the
one that matters is `resident`, which gates the verdict. datalogic has **no regex** — `match` is a
`switch`. Orion refuses `env://` in a connector URL, and caps a workflow description at 2048
characters. And the release-existence call was dropped rather than fixed: a missing tag 404s both
asset URLs, and `ASSET_MISSING` naming the exact URL beats the `RELEASE_NOT_FOUND` it replaced.

## 4. The three that cost the most

`metadata.vars` is root scope like
`data`, so a `[vars]` value read inside a `map` body is `null` — and `{">=": [0, null]}` is true, so
reading the strike ceiling there forfeits every seat on turn 0 and kills the wave a turn later at
`step`, naming neither the variable nor the cause. Drain is three numbers and the smallest wins, and
`[server] shutdown_drain_secs` is a fixed period rather than a maximum, so it is exactly what every
scale-down costs.

> **The rule drawn from that measurement was wrong, corrected in [`deployment.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/deployment.md) §6.1 from
> `orion-server`'s source.** "All three must exceed the longest match" tells an operator to raise
> `shutdown_drain_secs`, which is the one number paid unconditionally, and leaves at its default the
> one that would have helped. The cron worker is a *supervised task*, and `main.rs` drains the
> supervised tasks under `server.shutdown_force_timeout_secs` — so the bound on a wave is
> `min(cron.shutdown_timeout_secs, server.shutdown_force_timeout_secs)`, an inner deadline under an
> outer one, and the cron key can only ever make it shorter. That is why cron at 2 700 with the
> server keys at 30 measured 30. `shutdown_drain_secs` exists for a load balancer's in-flight
> requests and buys a cron-only replica nothing.

And a cron occurrence's data is readable nowhere — not in its return, not in its
trace — which is why Kalam's config now mounts a development-only REST path: without it the two
bugs above would still be unfound. §2 above has the full list.

## 5. Rating and seasons

| Finding | What it means |
|---|---|
| **A version alone in its weight class never settles.** The demand view judged `played` as the smaller of a version's two ladder counts, and a class ladder with nobody else in the class is never fed | It was `placement` for ever: cap `burst`, demand never fell, and the local stack's one Micro version played 4,430 matches against Nano baselines with sigma 0.70. A class ladder now counts only when another active version of the class is in the season; the close predicate inherits the rule |
| **A `finished` row count has not folded yet is in flight**, and the demand view did not count it | In the ten seconds between Kalam finishing a burst and count folding it, `played` was still 0 and `in_flight` was 0, and pair inserted a second burst. `finished` is in the in-flight set now |
| **The 2048-character workflow description cap bites on a revision too**, and the load script sweeps before it re-creates | Appending a paragraph to `soma-submissions-create`'s description pushed it over; the package load stopped there, after the sweep and before the channels, so every Soma endpoint was gone until it was fixed. Keep descriptions short; the reasoning belongs in the design document |
| **Two REST channels may share a `route_pattern` when their methods do not overlap** (`definitions/check.rs`, `duplicate.route_pattern`) | `GET` and `POST /v1/games/{game}/seasons` are two channels, two workflows |
| **`db_write` reports only `rows_affected`, so a statement that must report success ends on the write that means it** | The season create is one statement whose CTEs insert the season, carry the baselines and seed them, and whose *last* statement is the roster bump: one row on success, zero when refused. Soma then reads the season back. Whether `db_read` accepts a data-modifying CTE was never needed |
| **`psql -v var=… -c "…"` does not expand `:'var'`**; only a script on stdin does, as the loader's comment already said | A one-line `-c` that looks right fails with a syntax error at the colon. Every hand-driven statement went through a heredoc |
| **A shell `$(psql … RETURNING …)` capture includes the `INSERT 0 1` tag** | A user id captured that way was 47 characters, and the JWT built from it failed at the query's `uuid` cast; Orion's error named the length, which is what found it. Capture with `-At -c "SELECT …"` |

---

## 6. The deploy step

| Finding | What it means |
|---|---|
| **`/health` reports each loaded plugin's DIGEST, not merely its name** — `.plugins.loaded[] \| {plugin, version, digest}` | Decision 44 says the digest is declared *last, once the new replicas exist and are loaded*, and that precondition is now **checkable rather than assumed**: `declare-engine.sh` refuses to flip the column unless at least one replica's `/health` reports `tb.ants` at the digest being declared. It is a strictly tighter gate than the loader's `health()`, which asserts only that a plugin of that *name* loaded — a replica carrying the wrong engine passes the name check and claims nothing |
| **A plugin version bump does not change the component digest.** `ants` at 1.0.0 and 1.0.1 — `Cargo.toml`, `plugin.toml`, `cargo test`, `cargo build --release`, `wasm-tools component new` — produce `tb-ants.wasm` byte for byte identical, `sha256:f6ee986b…` both times | The engine's identity on the platform is the **content hash**, and `plugin.toml`'s `version` is independent of it. Two consequences. The build is reproducible across a version change, which is what the determinism guard wants. And **a "new engine version" is not a new engine**: a deploy that bumps the version and expects a rolling cutover gets one digest, one queue, and no roll at all. Only a source change mints a new digest — which is the right law, since the digest is what a played row records |
| **`ratings.matches_played` is the rating-event sequence, not a counter.** `rating_events_pkey` is `(model_id, ladder, seq)`, and `seq` is that column | Resetting it to put a played version back into placement makes count fail its very next fold — `duplicate key value violates unique constraint "rating_events_pkey"` — and the clock stays broken, retrying and failing every ten seconds, until the counter is at or above `max(seq)` again. **A version with history cannot be returned to placement by resetting the counter**: placement is a property of what a version has played, and the audit trail enforces it. Anything that restores a `ratings` row from a backup must restore `matches_played` to at least `max(seq)`, not to whatever the backup said |
| **Recreating a Kalam replica orphans its `axon` sidecar.** `network_mode: "service:kalam-N"` puts the sidecar in the replica's network namespace, and `--force-recreate kalam-N` gives the replica a *new* namespace while the sidecar stays attached to the destroyed one | The replica comes back **healthy**, claims rows, and then every wave fails at the residency barrier: `Task resident failed: Io("HTTP request to http://127.0.0.1:9090/resident failed")`. Rows go `claimed` and lapse. Nothing in `/health` says why, because the replica's own health *is* fine — the thing it talks to is gone. **Recreate the sidecar with the replica, always**, and read "the wave fails at `resident` right after a replica restart" as this until proven otherwise |
| **`/health`'s plugin digest is not the replica's claim digest.** What gates claiming is `[vars] engine_digest`, and no admin endpoint exposes it — not `/health`, not `channels` (whose `config` carries only timeout and tracing), and `/api/v1/admin/{config,vars,settings,instance}` are all 404 | They agree in a real deployment, because the entrypoint derives the var from the vendored component, so a preflight that reads the plugin digest is exact there. They **diverge under `KALAM_N_ENGINE_DIGEST`**, which is exactly what a rehearsal pins. So `declare-engine.sh`'s per-replica attribution — "will claim" vs "will drain" — is right in deployment and wrong in rehearsal, while its *conclusion* (at least one replica can claim) holds in both. Driving it proved this: the preflight reported "2 will claim, 0 will drain", and the pinned replica then drained |
| **A load-time signature refusal is fully legible in `/health`** — `status` goes `degraded`, `plugins.failed_to_load[]` carries `{plugin, version, digest, stage: "signature", reason}`, and `channels.quarantined[]` carries the whole causal chain: *"no handler is registered for `tb.rating.trueskill` … tb.rating v1 signature: the signature does not verify over sha256:… with any of the 1 configured key(s)"* | Verified by pointing a node's `[plugins.trust] public_keys` at a key that did not sign its stored plugins. This is what makes trust safe to turn on: the failure is **not** the silent one. It also means the invisible-capacity check a deploy already runs — `/health`'s plugin digest plus `channels.quarantined`, which `declare-engine.sh` reads — catches a trust misconfiguration for free, without a check of its own |
| **Turning trust on refuses the plugins already in the state database.** They were uploaded before there were keys, so they carry no signature, and the node that now has keys will not load them | The fix is a re-upload — `docker compose run --rm loader load` — not a restart. Worth knowing because Soma's state is Postgres and *survives* the restart, so the package looks present and simply does not run. A replica hides this by being disposable: its SQLite state is empty on boot and the loader re-uploads anyway |
| **`admin_auth` silently shrinks `/health`.** The detail — `workflows_loaded`, `plugins.loaded`, `plugins.failed_to_load`, `channels.quarantined` — is gated on `show_detail = !admin_auth.enabled \|\| a valid admin key` (`server/routes/mod.rs`). Unauthenticated, the endpoint still answers **200** with the coarse component states and simply omits those keys | This broke two checks the moment trust was turned on, both in the same direction: the loader's per-replica assertion reported **"tb.rating IS NOT LOADED — this node is invisible capacity"** about a node whose log said `Plugin loaded` a second earlier, and `declare-engine.sh`'s preflight would have refused a cutover on a fleet that was fine. **The check written to catch invisible capacity became a source of it.** Every reader of that detail now sends the credential, and the preflight distinguishes *hidden* from *absent* — `has("plugins")` false means "authenticate", not "no plugins" |
| **`EXPLAIN` permission-checks without executing**, so it is the cheap way to prove a role's grants cover a statement | `jodi/scripts/check-sql.sh` now runs all 21 shipped statements through `EXPLAIN` as the `jodi` role against a scratch database: nothing runs, and a statement needing a grant the role lacks fails with `permission denied for table X` naming the table. PREPARE cannot do this — it parses and plans but never checks privileges, which is exactly the gap that lets a statement pass CI and fail on a cron tick |
