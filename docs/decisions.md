# Decisions — Soma

Why Soma is shaped the way it is: the part of TinyBrains' decision record about this
repository. One line per decision, with the reasoning kept and the cost of flipping it named where
that was worked out.

> **The record was one file until 17 September 2026**, `devops/docs/decisions.md`. When devops
> stopped running anything (N25) it was split, so each decision lives in the repository it is
> about. **The numbers are the record's, not this file's**: they were assigned once across the
> platform and are never reused, so a citation of `41` or `N24` names one decision wherever it now
> lives, and a section number below is the one the whole record gave it.
>
> **Four numbering series.** The **A-series** is the twenty-one architectural decisions taken
> before anything was built. The **plain series** is the build decisions the layers took, numbering
> from 1 again, so `A5` and `5` are different decisions and a bare number in a code comment means
> the plain series. The **R-series** is the Orion 1.8.1 rebuild and the **N-series** the runner, the
> submission path and where each repository's artifacts come from.
>
> **`jodi` merged into `soma` on 16 September 2026 (N19).** Every decision below that names Jodi was
> taken while the clocks were a package and a repository of their own, and is kept as written. The
> clocks, their plugins and admission are Soma's now, under the same channel and plugin ids, so
> *Jodi* in an entry means Soma's clocks.
>
> **`ants-baselines` moved into `ants` on 16 September 2026 (N20).** An entry that names
> `ants-baselines` means `ants/baselines/`.

## Where the rest of the record is

| Decisions | Where they live |
|---|---|
| **A1–A21**, §2's review findings and the Orion changes asked for | [soma](https://github.com/Tiny-Brains/soma/blob/main/docs/decisions.md) |
| Plain series: the match table (2, 3, 7, 7c, 7d, 18, 21, 22), the clocks (1, 7–13, 23, 24, 28, 51–59), admission (20, 35–40), the retired loader (6, 34, 46, the adapter cap) and deployment 43, 44, 48 | [soma](https://github.com/Tiny-Brains/soma/blob/main/docs/decisions.md) |
| Plain series: the wave (19, 33) and deployment 5, 25, 41, 42, 45 | [kalam](https://github.com/Tiny-Brains/kalam/blob/main/docs/decisions.md) |
| Plain series: the game and the protocol (4, 14–16), the baselines (49, 50 of the loader's) | [ants](https://github.com/Tiny-Brains/ants/blob/main/DECISIONS.md) |
| Plain series: the training environment (47, 48 of the loader's) | [cli](https://github.com/Tiny-Brains/cli/blob/main/DECISIONS.md) |
| Plain series: deployment 47 and 49 (the compose file's) | [web](https://github.com/Tiny-Brains/web/blob/main/DECISIONS.md) |
| **R1, R2, R4, R6, R9, R10, R11** · **R3, R7, R8** · **R5** | soma · kalam · ants |
| **N3, N6–N8, N12, N13, N15–N19, N28, N29** · **N1, N2, N4, N5, N9** · **N20–N22, N24, N27** · **N23** · **N25** | soma · kalam · ants · cli · web |
| Still open | the repository each is forced in: 30, 31, N14 and three unnumbered in soma; N10 and a runner on another network in kalam; 32 in ants; 26, 27, N11 and the orchestrator in web |

The plain series collides with itself once: the retired loader's **47, 48, 49** and deployment's
**47, 48, 49** are different decisions, told apart above by where each lives.

---

## 1. Architectural decisions

| # | Question | Decision | What it fixed |
|---|---|---|---|
| A1 | Where does the game engine run? | A plugin inside Kalam | one process per replica |
| A2 | Who owns the game-to-tensor transformation? | **The competitor**, declaratively, submitted with the model. The game defines only its JSON shapes | the evaluator in Axon; admission validates adapters through it |
| A3 | What is one row? | **One match**, carrying the players and their model details; a replica claims and plays a wave of such rows | the engine stays wave-shaped; one inference per distinct model per turn, per replica |
| A4 | Where does a finished match go? | **The same row**, finished in place; a status column separates queue from history. Not a second table | one table; finish is an update conditioned on the claim token |
| A5 | Who rates and who lists? | **Jodi's count clock**, under a fence, in finish order; Kalam publishes results only and Soma lists | rating math in Jodi's package; the mark on the row |
| A6 | The match maker in several instances? | Soma scales by load; Jodi is a **cluster-wide singleton** | cluster mode is a requirement, not a refinement |
| A7 | Trials? | Visible to the competitor, identical to any match, only unrated; count decides them | a trial is an ordinary match |
| A8 | Replays? | A JSON blob only the visualiser understands, **in the object store**, keyed per attempt; the key on the row | — |
| A9 | The match maker's name | **Jodi** | — |
| A10 | The game manager's name | **Kalam** | — |
| A11 | The Rater | **Not a part.** Counting is Jodi's | — |
| A12 | A superseded version's queued matches? | **Withdrawn in the statement after the flip**, ordered by the roster fence, to a terminal `cancelled` naming the successor; claimed and running ones finish and count; never re-pointed at the successor | Kalam stays roster-blind |
| A13 | What does Jodi do? | Withdraw, pair, count — and, since admission, admit. Pairing takes the versions whose rating has not settled and spreads their matches across the game's maps; a settled version plays as an opponent | — |
| A14 | In what order? | **No order.** Cron channels, each its own schedule and singleton key; they meet only in rows, and every write is fenced | — |
| A15 | Correct without the lock? | **A fence per clock** in a `clocks` table; a stale run writes nothing and halts. The rating math stays in the plugin, not in Postgres | the locks buy efficiency, the fences correctness |
| A16 | Who promotes? | **Count**, in the run that decides the trial row, in two statements under the roster fence. Not admission | the seed includes every match counted before it |
| A17 | Where does the adapter run? | **In Axon**, under an operation count the evaluator keeps and a deadline it enforces; the host's fuel and wall clock are backstops. Not an Orion plugin | — |
| A18 | One match per workflow run, or a wave? | **A wave per replica**: up to K rows claimed in one statement, one play call per turn, each row finished as its match ends | — |
| A19 | Which engine plays a row? | **The row says**: pair stamps the digest the deploy declares current, the claim filters on its own, withdraw cancels a retired one | the digests that played a match are recorded at finish |
| A20 | How does Kalam scale? | **Up on the demand view, down by drain** on SIGTERM | — |
| A21 | Who has a data path for admission? | **An Axon beside Soma**: fetch once, verify, inspect, validate, mirror to the object store; Kalam's loaders fetch by hash | — |

---

## 2. The twelve findings that forced them

The review that produced §1 found that four of the eleven system invariants did not hold as
written, two mechanisms had no owner, and the design had changed the platform's cost model without
pricing it. The verdict it sat under: **the split by scaling axis and the one-table contract are
the right seam, and the status walk is the best part of the design.**

| # | Finding | Decision |
|---|---|---|
| 1 | **Count is not correct without its lock.** | **A fence per clock** — the claim-token pattern Kalam already uses on the match row, applied to Jodi, so the design carries one idea rather than two. A `clocks` table holds one row per clock. The first task of a run claims the fence — the occurrence's `scheduled_for` and `attempt`, both monotonic per channel — by updating the row only if the stored fence is lower. Every ladder write carries a predicate that the fence row still equals this run's fence, read `FOR SHARE`, so the row lock rather than the snapshot orders the check. |
| 2 | **Promotion cannot withdraw "in the statement that supersedes it".** | **The roster fence** — the same table and predicate as finding 1, so the design carries one mechanism for "a stale run writes nothing" and "a stale roster pairs nothing". The roster key is a counter bumped by any roster writer, not a run fence, so `clocks` carries two flavours. Promotion is two statements: bump-and-flip, then withdraw. A crash between them is the withdraw clock's case. |
| 3 | **Ratings have two writers.** | **Count promotes**, putting every ladder write — the mark, the posterior, the seed, the flip and the roster bump — under one fenced run. |
| 4 | **The adapter budget is not answered by the host.** | The **evaluator counts operations** (logic nodes plus tensor elements) and carries its own deadline; the loader owns `turn_ms` across adapter, inference and adapter. Fuel and wall clock are backstops only. **The number came out at 1,000,000 — five times what was argued** — because a real adapter measured against a real observation said so. |
| 5 | **Two engine digests can rate into one ladder.** | The row carries **the digest it requires**, and the digests that played it are recorded at finish. Count does *not* refuse foreign digests (decision 13); what keeps a behaviour-changing engine out of a ladder is that a release is refused while a season is live. |
| 6 | **The trial path has no owner.** | Pair inserts, Kalam attributes, count decides; trials claim first. |
| 7 | **The lease and the attempt have no owner.** | The claim reaps lapsed leases; a partial renew halts; refusals are counted apart from attempts; the replay key names the attempt. The attempt ceiling counts lapses only, and with drain, lapses come only from crashes — so **three**. |
| 8 | **The scaling signal is capped by the thing it measures.** | A **demand view**, not queue depth: pair tops the queue to a target, so depth could never distinguish two missing replicas from twenty. Drain by SIGTERM on the way down. |
| 9–11 | **The batching economics are gone; per-turn work multiplies; the reason Kalam is on Orion is also its largest cost.** | **The evaluator in the loader, waves per replica.** It restores the economics the design was built on, cuts the per-turn task count by the wave size, and answers "why is Kalam on Orion" with the loop as a workflow, the engine as a plugin, and the claim, lease and finish as SQL. **Measured afterwards: batching is worth 1.11× at Ants' full board, not an order of magnitude**, because every seat costs its own forward pass either way. The decision survives the correction; the argument for it was overstated. |
| 12.1 | Lease renews are updates on the permanent history table every few turns | **Keep the columns on `matches`, index none of them, set a fill factor** so renews are heap-only updates. A narrow claims table only if vacuum shows it. |
| 12.2 | Kalam's credential can touch any table | **A dedicated role** with column-level grants. One statement, and it makes the rule a fact rather than discipline. |
| 12.3 | Every replica fetches every model from GitHub | **An admission-side loader fetches once, verifies, inspects, validates and mirrors to R2**; Kalam's loaders fetch by hash. GitHub is touched once per submission, and a competitor deleting their release cannot break their own replays. |
| 12.4 | The endpoints keep their paths but not their shapes | **Additive fields**, so a competitor is still told why a match never happened. |
| 12.5 | Forfeit ranks have no owner | **Kalam overrides ranks at finish**, forfeited seats last, the engine's ranks kept in the replay envelope. Telling the engine is refused; letting the engine's result stand would let a timed-out model win on points. |
| 12.6 | **Admission has no data path** | Answered by 12.3: the loader is a part on both sides. The two Orion packages still share no workflow. |

### Orion changes worth asking for

Not required by any decision above, and listed so they are not confused with the fixes.

| Change | Earns its place because | Needed by |
|---|---|---|
| Per-channel, per-node concurrency cap on cron | Kalam wants K matches in flight per replica per channel; the only knob is `cron.workers`, node-wide across every channel | Kalam — **downgraded, not withdrawn**: a `forbid` singleton is already per-replica state, so this is wanted only if a replica ever wants more than one wave in flight |
| A monotonic fence integer in `metadata.trigger` | Ergonomics only; `scheduled_for` plus `attempt` already serves | nobody |
| **A URL-valued artifact reference** on the `models` entity — a node fetches a governed model from a presigned link, holding no credential for the store | `ArtifactRef` is `{connector, key, digest, size?}` with no URL variant and `StorageProvider` has one value, `S3` (re-checked against the pinned 1.8.1 source on 16 September 2026). So an off-site runner must hold *some* storage key to fetch weights, where the replay beside them is already a signed URL the gate hands out. N4 makes that key harmless; this would make it unnecessary | an off-site runner (N4). **Not filed yet** — filing is what stops the workaround becoming permanent by default |

**The nine that were asked for, and shipped.** Studying 1.8.0 for the rebuild produced nine issue
bodies, filed on 14 September 2026 and **all nine closed in `v1.8.1` the same day** —
[#318](https://github.com/GoPlasmatic/Orion/issues/318),
[#323](https://github.com/GoPlasmatic/Orion/issues/323)–[#330](https://github.com/GoPlasmatic/Orion/issues/330),
plus [datavalue-rs #1](https://github.com/GoPlasmatic/datavalue-rs/issues/1) and
[datalogic-rs #70](https://github.com/GoPlasmatic/datalogic-rs/issues/70)/[#71](https://github.com/GoPlasmatic/datalogic-rs/issues/71)
two days earlier. Eight got the fix that was asked for; **#328 closed with a different change and a
reason**, which is [`orion-notes.md`](orion-notes.md) §0.3 rather than a decision. What each one
bought is visible in the R-series below: the named axis (#318) is R2, `ops`/`peak_ops` (#324) is
R6 and R10, every-carrier `parameters` (#325) is R4, `preload_tags` (#329) is R8's topology. Two of
the nine shipped with no CHANGELOG entry, so **read `git log v1.8.0..v1.8.1`, not the release
notes**, when checking what a tag contains.

> **File upstream generically.** All nine bodies described "a ranked ladder running
> competitor-submitted ONNX models" and named no repository, path or game of this platform's. So did
> the three datalogic/datavalue ones. Anything filed later should keep to it.

---

## 3. Build decisions

Numbered as the build numbered them. Each names the repository it now lives in.

### The match table — [`soma`](https://github.com/Tiny-Brains/soma)

| # | Decision | Taken as | Why |
|---|---|---|---|
| 2 | Seat shape | **a `match_seats` table**; jsonb only for the two ladder-keyed rating facts | every read is a plain join, Postgres refuses a dangling seat, Kalam's grant is column-level on both tables. A single document was set aside because three writers fill a seat at three moments and a column grant cannot bound Kalam inside one |
| 3 | Seed columns | **kept**: a promoted version inherits its predecessor's `mu` per ladder with `sigma` inflated and capped at the prior | continuity for a competitor who iterates, and informed first pairings; a column read beats a jsonb query for the one question an auditor asks |
| 7 | Lapse ceiling | 3, in a `CHECK` and the reap | with drain, lapses come only from crashes |
| 7c | Refusal ceiling | a parameter, Kalam's number | — |
| 7d | Replay key per attempt | by claim token, not attempt number | the token is minted per claim and already on the row; no counter to keep in step |
| 18 | One preset per wave | **yes**, in the claim's fill clause | `worldgen(seed[], preset, players)` takes one preset; the cost is throughput under many presets |
| 21 | Verified state | **a `verified` status value**: `testing → verified → active \| rejected` | one predicate everywhere, and `SELECT status` tells an operator the whole story |
| 22 | Rating history | **a `rating_events` table**: one row per seat per ladder per counted match, plus a `seq = 0` row for the seed | every read is a join an operator can write; the primary key is finding 1's chain constraint for free; the history survives whatever retention does to match rows |
| — | Promotion as one statement | kept; the one-active rule is a deferrable exclusion constraint | correctness rests on constraint semantics the manual specifies, not on the order Postgres runs CTEs |
| — | The rating mark | `status = 'rated'` with `rated_at` and `rated_seq`; a trial is `rated` with no `rating_change` | one status walk, one mark |
| — | The reap | its own statement before the claim | a CTE's writes are invisible to the claim in one snapshot |
| — | `models.adapter` | **the release asset's exact text**, with a check that it hashes to `adapter_hash` | as text it is self-verifying where jsonb would not hash |
| — | The schema is initial | `CREATE TABLE`s, not a migration chain | nothing is released; a migration chain would version a schema nobody runs. **Versioning starts at the first release.** |

### The clocks — [`soma`](https://github.com/Tiny-Brains/soma); taken in `jodi`

| # | Decision | Taken as |
|---|---|---|
| 1 | Matches in flight per version | **a policy by state**, not a fixed cap — a placement burst for a new version, a small number in steady state, none once settled, one for a trial; baselines paced like every version (decision 28). It is what the demand view counts |
| 7 | Count's schedule and batch; pair's schedule and depth target | 10 s and 50; 15 s and 64 |
| 8 | The settled threshold and the re-pair cap | sigma 3.0; 3 trials |
| 9 | The cross-class fraction | 0.20 |
| 10 | The cold fraction | **dropped**: residency is Kalam's, staleness is `tau`'s |
| 11 | Sigma inflation at seed | **the rule is final** — inherit `mu`, multiply `sigma`, cap at the prior, store both; the number stays 2.0 |
| 12 | Rank ties | **final: equal ranks draw**; numbering style never reaches the update |
| 13 | Count refusing foreign digests | **no** |
| 23 | Season scope | **per game** — everything a season holds is per game, and closing when settled cannot be shared |
| 24 | Retention | **a policy table**: standings forever, match rows indefinitely, replays by a bucket lifecycle rule, traces by Orion's config |
| **28** | **Baselines are ordinary entries on the ladder** | Decided 11 September 2026. A baseline is paired, paced, rated and ranked like any version, held to `pairing.queue_share_max` like any owner, and must settle before a season closes by settling — the demand view gives it no state of its own and reads no role. Two things set it apart: the `baseline` tag every read route carries, and `P_TRIALS`, which seats one opposite every trial and is the only statement that reads `users.role`. How one arrives is unchanged — seeded, then carried into each season by the create — because the carry is what guarantees every season a trial opponent. Before this a baseline's cap was zero: it played only when someone else's demand picked it, so a fresh stack sat idle and its ratings moved only on other people's matches |
| — | The dynamics factor | **`tau` per update; no clock inflates a sigma** — frozen weights do not drift, and a clock that re-opened sigma would hold a season open forever |
| — | What a season is | **an admin-created window**: opening date, last submission date, closes itself when settled |
| — | A version's season | **one, stamped at submission** — a version never crosses a boundary, so nothing is re-keyed |
| — | Non-overlap | **a partial unique index on the live season**, and the gap checked at create against the previous close |
| — | Who closes a season | **withdraw's second task**, by the settle predicate or an admin's intent — no fifth clock |
| — | Where the engine digest lives | **the deploy declares it on `games`, the season pins a copy** — the two mean different things and a difference is a fact |
| — | Baselines | **carried into each new season by the create**, as new `model_versions` rows against the entries they already have, at the prior — and an ordinary version of the season from then on (decision 28) |
| **51** | **An entry and a version are two tables** | `models` is the entry — a competitor's named lineage, keyed by the GitHub repository it publishes from — and `model_versions` is one submission of it. Everything a rating, a seat or a match points at is a VERSION; a rename, a retirement and a quota are about the ENTRY. Before the split "the entry" was spelled `(owner_id, game_id)` inside seven statements, which is why a competitor could hold exactly one. Uniqueness is `UNIQUE (game_id, lower(repo)) WHERE owner_github_id IS NOT NULL` — ONE ENTRY PER REPOSITORY, platform-wide. It was `(owner_id, game_id, lower(repo))`, with the cross-competitor half argued rather than enforced: it was said to follow from `repo_owned()`, because a repository's first path segment had to be the competitor's own login. That was false — the check compared login STRINGS, and two rows holding one login in different cases both passed it for one repository. Decision 58 made it true, and a true claim is kept true by an index. The partial predicate is the only exception and it names itself: a row with no `owner_github_id` never went through the route, which is the three seeded baselines sharing one repository |
| **52** | **The season's rules are the whole description of a contest** | `seasons.rules`, ten blocks, validated by `season_rules_ok()` against a `season_rule_spec()` VALUES table so the spec IS the documentation. Every rule is read `coalesce(rule, <the [vars] value>)`, so a season that declares nothing behaves exactly as the deploy does. **This closes decision 29**: quotas are season rules and not a global table, because a quota is a property of the contest it belongs to and travels with it. The CHECK it replaces enumerated two block names and looked no further, so `{"participants": {"enabld": true}}` stored cleanly and then admitted the world |
| **53** | **A participant list is matched at submission, not resolved at creation** | A cohort is a list of GitHub logins written before the term starts, and most of its members have never signed in. Resolving once and keeping only the ids would silently refuse exactly those people for the whole season. The handles are stored as given and matched against `users.handle` — which IS the GitHub login, rewritten by the auth upsert on every sign-in — with the ids that do resolve kept beside them as the fast path |
| **54** | **The strike ceiling is pinned on the match row** | `matches.strike_ceiling`, stamped by pair, read by Kalam off the row it claimed and by count off the trial it judges. Kalam's own `[vars] strike_ceiling` is deleted and `configs.sh`'s equality assertion with it: the documented cross-repo footgun disappears because Kalam stops keeping a second copy, not because Jodi stops keeping the first. NOT NULL is the point — with both the season and the deploy silent, pair halts at its insert, where a halt is correct, instead of Kalam comparing a strike count against null (which is TRUE) and forfeiting every seat on turn 0 |
| **56** | **A quantised-only season reads the WEIGHTS' dtypes, not the ports'** | `/inspect` gained `weight_dtypes`: every distinct element type the initializers declare, read off `TensorProto.data_type` rather than inferred from which payload field carried the bytes. The graph's input and output dtypes were already reported and say nothing about this — a network with float32 ports may hold int8 weights, which is what quantisation IS. An unrecognised type number becomes `type-<n>` rather than being dropped, so a future ONNX dtype cannot pass a quantised-only season by being unnameable |
| **55** | **Self-pairing is refused by the INSERT, not only by the plugin** | Two versions of one owner in one match is a free rating transfer between a competitor's own models: the ladder is *wrong*, not merely worse, so it is correctness and belongs in the statement. The plugin declines to propose one; the insert refuses one anyway. `P_TRIALS` was made owner-distinct first, because a trial is plan item 0 and a trial the insert refuses would halt pair every run, for ever |
| **57** | **A GitHub login is a label; the account id is the identity** | `users.handle` is a cache of a mutable remote value, rewritten only at sign-in, and it was carrying authorization: `repo_owned()` and `season_admits()` both decide on it. Three sign-ins died on its unique index — a new account taking a login freed by a rename, an account renaming into a login a stale row held, and a real account whose login equalled a seeded baseline handle, which could never sign in at all. Uniqueness moves to `lower(handle)`, the namespace the readers actually compare in; the baselines move to `baseline.<artifact>` and a freed login is parked under `released.<github_id>`, both unmintable because a login is `[A-Za-z0-9-]` and neither contains a dot; and sign-in releases the login from the provably-stale row before claiming it, in a STATEMENT OF ITS OWN — as a data-modifying CTE the release and the upsert share a command id and the release is not reliably visible to the insert's uniqueness check. This fixes the crash and the case hole and NOT the staleness: `users.github_id` is the column a decision about identity belongs on, and nothing reads it yet |
| **58** | *(superseded by N13 — the field it decided is gone)* **Ownership is resolved once, at entry creation, and compared by account id** | `soma-models-create` calls `GET /repos/{owner}/{name}` and compares `owner.id` with the caller's `users.github_id`, then records both the id and the login on the row. Comparing the login instead decided ownership on a cache of a mutable remote value: an account that renamed away from `alice` went on owning `alice/*` until it next signed in, and a cohort naming `alice` admitted it. ONCE, because a repository is the entry's and never a submission's, so this is not on a hot path. IT FAILS CLOSED — when GitHub does not answer the creation is refused 503 `repo_unverified`, and never falls back to the login comparison, because that fallback is the hole and anyone could reach it by exhausting the rate limit. The token is optional in code and required in practice: unauthenticated is 60 requests an hour PER IP, and the IP is the server's, so `check/configs.sh` says out loud when `GITHUB_TOKEN` is unset. Two sibling tasks with opposite conditions, because a header cannot be conditionally omitted and an empty `Bearer` would 401 sign-in too |
| **59** | *(superseded by N13 — the field it decided is gone)* **An organisation allowance requires a declared cohort** | `repo.allow_orgs` widens ownership to repositories nobody has proved they own, and on its own it widened it to everyone: season 1 shipped `allow_orgs: ["Tiny-Brains"]`, which let any signed-in competitor create an entry on `Tiny-Brains/ants-baselines` and submit the platform's own baseline release as their own model — the hashes are public on `GET /v1/models/{id}`, release uniqueness is per model, and `unique_weights` defaults off. Every real use of the key is a cohort (a lab, a class), so `season_admits_repo` honours it only for people `season_admits` already admits, and `season_rules_ok` refuses the key without `participants`. The baselines never needed it: they are seeded by INSERT and never reach the route, so the seeded rule bought nothing |
| — | The season's rules | **a document on the season row**, each rule under its key with an `enabled` flag, checked as predicates in the submission insert |
| — | Verdicts in the same run as the fold | yes: one loop over one document, folds first |
| — | Pair claims no run fence | the roster fence is the guarantee; a retry overfills by at most one run |
| — | The trial insert is SQL, not the plugin | the choice is mechanical and must not depend on the plugin's state |

### Admission — [`soma`](https://github.com/Tiny-Brains/soma); taken in `jodi`

| # | Decision | Taken as |
|---|---|---|
| 20 | The admission timeout | **180 s per attempt, 3 attempts, then `TIMED_OUT`.** It covers verification only; a trial never times out the candidate. The number is set by `zstd -19` over a `Large` model |
| 35 | Does the competitor declare the hashes? | **Yes, both, at submit** — it lets a competitor verify what was admitted, and pins the bytes across a retry. `POST /v1/submissions` refuses `400` when either is missing or malformed |
| 36 | Where admission runs | **A fourth clock inside `jodi`.** Jodi is the version's life cycle, not just the match maker |
| 37 | Does admission need a run fence? | **No.** The per-row claim is the mutual exclusion, and is strictly better here: a dead run releases what it had not reached at once |
| 38 | Where the game's budgets and reference observations live | **`games.manifest` and `games.reference_observations`** — not `[vars]`, so a second cartridge is content |
| 39 | What a dialect change does to admitted versions | **Re-validate as the tail of the admission run**; reject on failure and let withdraw sweep the queue |
| 40 | The stale-admission lockout | **Replaced by the trial wait, made visible.** Nothing sweeps a `verified` version |

### The loader — ~~`axon`~~, **superseded 14 September 2026**

> **Every decision in this section was taken about a service that no longer exists**, and the
> checkout is gone from the working tree. Orion 1.8.1's `models` entity replaced it whole — §4's
> R-series is what replaced each one. They are kept because a
> decision log that deletes what it superseded cannot be read backwards: **46** (there is no compute
> cap) and **49** (the baselines are a repository of their own) still stand on their own arguments,
> and the rest are the reasoning the R-series answers. Where an entry below and the R-series
> disagree, the R-series is what runs.

| # | Decision | Taken as |
|---|---|---|
| 6 | The op budget number | **1,000,000**, measured rather than argued: a reference six-plane Ants adapter costs 197,272 against a real worst-case observation |
| 34 | The resident call | `GET /resident`, advisory, weights hashes, `loading` excluded |
| — | A tensor is opaque to a program | the encoding question disappears with the encoding |
| — | The operator set is the platform's, and has no arithmetic | marshalling is priced by the op count, knowledge by `S`. The third axis — computation — was the FLOP cap, retired by 46; the no-arithmetic rule survives on the op count's own cost rule, which prices data and not multiplies |
| — | The count is a run-time count | the static bound stays rejected, and the consequence — an adapter can fail at play having passed admission — is accepted and made visible as a strike |
| — | `dialect_version` and `evaluator_digest` are different things | the digest hashes the dialect, not the binary, so the re-validation sweep fires on meaning and not on releases |
| — | `/load` takes hashes; only admission takes URLs | the store key *is* the hash, so resolving it is content addressing, not platform knowledge |
| — | The mirror happens inside admission's `/load` | there is no state where a version is admitted and its bytes are not in the store |
| — | `fault: model \| loader` on every refusal | Kalam branches on a field, not a vocabulary, so a new reason word costs no workflow change |
| — | The graph is timed at the shapes the adapter actually produced | a declared input shape is a claim; what is fed is a fact |
| **46** | **There is no compute cap. `turn_ms` is the fairness control** | measured 10 September 2026 and recorded in axon/docs/design.md §10.2: `2·params·spatial` was shadowed by `S` below and by the deadline above, decided something only for a quantized Nano or Micro entry, and could not catch the few-bytes-much-compute exploit it was introduced for, because that exploit minimises `params`. Prerequisite, landed with it: the loader gives each row its own share of `deadline_ms`, so a slow graph times *itself* out instead of striking the seats behind it. `models.infer_us` replaces `flops_estimate` — reported to the competitor, gating nothing |
| — | The adapter's raw cap | 4 MiB |

### Deployment — decided in `devops`, which runs nothing since N25

| # | Decision | Taken as | Why |
|---|---|---|---|
| 43 | What the autoscaler reads | **demand, never depth** | `pair_depth_target` caps the queue, so depth would cap the fleet and look correct doing it |
| 44 | When the deploy declares the digest | **last**, once the new replicas exist and are loaded | before it they claim nothing; after it the old ones cannot. The column is the cutover switch |
| 48 | Where the schema is applied | **`db-bootstrap`, a step that runs on every bring-up**, not Postgres's `/docker-entrypoint-initdb.d` | that directory runs once per db volume and is skipped on an existing one, so a pre-release schema rewritten in place never reached a running stack — it surfaced as `relation "clocks" does not exist` on a count tick. Bootstrap applies the migrations only into an EMPTY database (re-running `CREATE TYPE` is an error, not an upgrade), records `sha256` over them as the per-database setting `tinybrains.schema_digest` (no table, so Soma keeps sole schema ownership), and refuses a mismatch by name. A service of its own because a cluster-mode node cannot start until `orion_state` exists |

---

## 4. The 1.8.1 rebuild — the R-series

Taken 14 September 2026, when Orion 1.8.1 made its `models` entity a strict superset of what `axon`
does. Each is **measured where it could be measured**, and the numbers are in the rows themselves —
taken with `orion-server dry-run --model-dir` against the real baselines, not estimated. A third
numbering series, because these overturn A-series decisions rather than extending the build series.
The study they came out of is in this repo's git history (`docs/migratingv18.md`, deleted
15 September 2026); what survived it is here and in [`orion-notes.md`](orion-notes.md) §0, with the
three measurements still owed named in this repo's `README.md` Status block.

| # | Question | Decision | What it overturns, and what it cost to check |
|---|---|---|---|
| R1 | Where does a model run? | **Orion's `models` entity**, on the node that needs it — `tract` on the CPU, an artifact fetched from the bucket by connector and digest. `axon` is deleted, with the `tb.*` dialect, `evaluator_digest`, the residency barrier, the fetch allowlist and the sidecar-per-replica topology | **A17** and **A21**. Checked first: tract's answers match `ort`'s to `max\|Δ\| ≤ 1.7e-5` on the three shipped baselines over real boards, and the **argmax agrees on 100% of cells** — the action is an argmax, so the ladder plays the same game |
| R2 | How does a manifest describe a board that changes size? | **A named dimension.** `"shape": [1, 7, "H", "W"]`, bound per call, with `probe_dims` naming what admission probes at. No season ceiling, no padding, no validity-mask plane | Nothing — 1.8.0 could not express it and the design that worked around it never shipped. Measured: symbolic costs ≈1.4× on two baselines and **saves 5–14× on the third** (tract's optimiser picks a bad plan for a fixed-shape pure-Conv graph: 40.1 ms fixed vs 2.9 ms symbolic at 128×128). Against the padded alternative it is 1.7–36× cheaper, because padding runs every board at the ceiling |
| R4 | What measures a weight class? | **`S' = artifact_bytes + len(manifest)`** — the size the node measured against a digest it re-hashed, plus the document Jodi forwarded | `S = zstd-19(initializers) + zstd-19(adapter)`. Confirmed with an artifact: moving every initializer into a `Constant` node is 8 lines of `onnx.helper`, changes nothing the graph computes, and takes `axon`'s `params` and `S`'s first term to **zero** while `artifact_bytes` moves 51,796 → 52,326. Orion 1.8.1 reports 24,993 parameters for both, so `parameters` is now a second, independent check |
| R6 | What language is an adapter? | **datalogic's tensor family**, priced by `engine.ops_budget`, which stays at **1,000,000** | Decision 4 and 6 keep their number. Measured on the ported reference adapter: **86,051 ops at 64×96, 129,059 at 96×96, 229,415 at 128×128** — ≈14 per cell, and nearly flat in ant count. 4.4× headroom at the largest board the platform ships, against 197,272 for the old six-plane dialect adapter |
| R9 | What is a model id? | **`tb.v<uuid-with-hyphens-kept>`**, the version's own id | An Orion label is `[a-z][a-z0-9-]*` joined by `.`, so a bare uuid beginning with a digit is refused. One prefix, and the id is derivable from the row without a lookup |
| R10 | What forces a re-validation sweep? | **The Orion version**, recorded on the row in place of `evaluator_digest` | The sweep is per Orion upgrade rather than per adapter-evaluator build. `stats_output.ops` makes the drift measurable rather than assumed: the same adapter on the same observation reports its charge, so a sweep can compare two versions instead of re-admitting on faith |
| R11 | How do a model's bytes reach the platform? | **The competitor uploads them**, to two one-shot presigned PUTs Soma mints at `POST /v1/submissions`, under keys derived from the version id. Nothing on the platform fetches from a competitor's host | **12.3**, and with it the admission-side loader, its `AXON_FETCH_ALLOW_HOSTS` allowlist and the mirror-to-R2 step — deleted rather than ported. `model_versions.artifact_key` is `GENERATED` so the three readers of a version's bytes cannot disagree about where they are. Recorded late: the rebuild took this decision and every document cited it as R11 while the series stopped at R10 |

---

## 4b. The N-series — a runner leaves the deployment, and GitHub leaves the submission path

Taken and built 16 September 2026, as two tracks decided together because each removed a dependency
that was not earning its place. They shared one thread — the models bucket, which lets a runner read
artifacts without a secret and is the submission path's audit trail — and no file. The proposal and
its phased plan (`docs/design.md`, `docs/design-plan.md`) were deleted once they were all record;
what they argued is here and in [`architecture.md`](architecture.md) §3a, the statements and routes
are `soma/docs/schema.md` §3.8a, §4 and §4a, the operator's page is [`deployment.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/deployment.md)
§11, and what each phase turned up is in the Status blocks of `soma`, `kalam`, `devops` and `web`.
N10, N11 and N14 are still open, in §5.

### The runner

| # | Question | Decision | What it overturns, and what it cost |
|---|---|---|---|
| N3 | Is there model confidentiality to protect? | **No.** Every model is a public artifact of a public competition, and the models bucket is **public-read**. Replays stay private | Nothing was protecting them in a way that mattered. Since N13 the bucket is also the audit trail, which wants to be readable. Public-read on GET and the browser's cross-origin PUT (`deployment.md` §8.1) are independent settings, and `curl` checks neither the second nor its absence, because it sends no `Origin` |
| N6 | What is a runner's credential? | **An admin's runner key, exchanged for a ten-minute `aud: runner` JWT** at `POST /v1/runner/token`. A runner **self-registers** a `runners` row on `(key_id, label)`; nobody enrols a machine. Every statement EXISTS-joins `live_runners`, so revoking a key, revoking a machine or demoting its owner ends the **next call**, not the next token | `auth.mode: api_key` on every route: Orion resolves the accepted keys at channel load, so per-admin keys are unrepresentable and revoking one means reapplying the package — that is what makes the exchange necessary rather than ceremonial. `hmac` has the same one-secret-per-channel shape. mTLS is correct and moves the problem into certificate issuance for machines on desks; revisit if runners become long-lived fleet infrastructure. No exchange at all puts the credential that can finish a match in a shell history and a `docker inspect` |
| N7 | Where does the gate run? | **In the `soma` package**, on Soma's cluster-mode Orion — thirteen routes and `soma-runner-reap`. One generator, one loader, one tag to sweep, no second artifact image | The proposal's `kalam-gate`, a second package on the column-limited `kalam` role. Revised at build time, and **the cost was the column grant**: routes over `soma-db`, the owner, meant review rather than a grant stopped a runner statement writing a rating. N17 is the repair. The reap moved with it and is singular *because* that node is in cluster mode — the property a replica must never have (41) |
| N8 | Is the runner key readable, or hashed? | **Hashed**: `key_hash` (sha256) and `key_prefix` (`tbr_…`, the half that may be shown). `POST /v1/runner-keys` is the only response that ever carries the key | The proposal asked for a readable key so the admin UI could show it again. Hashed means a leaked *database read* no longer starts a fleet; the cost is that a lost key is replaced rather than recovered, which is the shape of every API key. Rotation is unaffected — `runner_keys` is a table, so an admin holds two keys and retires one |
| N17 | How is N7's weakened boundary repaired? | **A third role, `runner_gate`**, behind `soma-runner-db` on the eight machine-facing workflows: the `kalam` grants plus `UPDATE (played_by)`, the season and game columns the contract reads, `live_runners`, a new **`live_runner_keys`** view, and the `runners` upsert. The five admin routes stay on `soma-db`, because `runner_keys` is Soma's auth surface | **Widening `kalam`**, which the migration forbids because an in-cluster replica still holds that role. `live_runner_keys` was not foreseen: the token exchange joins `runner_keys` to `users` and the role must read neither, so the join lives in a view that runs with its owner's privileges. Measured: the role can claim, finish and read a season's rules, and **cannot** write a rating, read `users`, enumerate keys, promote a version, change a season or touch `clocks` |
| N18 | Do the terms a match is played under belong to the deployment or the season? | **The season**, as an `execution` rules block — `turn_ms`, `max_turns`, `refusal_ceiling` — read `coalesce(season rule, games.manifest.limits, [vars])` off **the row's own season**. `renew_every_n_turns` becomes a target the gate clamps to `floor(lease_seconds × 1000 / (3 × turn_ms))`, and `GET /v1/games/{game}` serves the **effective** limits | `[vars]`, which is where these lived only because the `kalam` role has no grant on `seasons` — the same reason `strike_ceiling` is pinned per match (54). Assembling the contract at the centre removed the constraint. The clamp is not tidiness: a season at `turn_ms = 5000` against a fixed 30-turn renew is 450 s against a 300 s lease, and every match lapses for a reason that names neither. It needed `models.max_timeout_ms = 60000` on every node too — Orion silently `min`s a longer deadline down to it, so a model was given one second of a five-second budget |

**Two properties the gate carries that the SQL role never had to.** A `finish` can now be delivered
twice, so the route writes and then reads the row back under the same token: `200 {applied: false,
state: "finished"}` is a duplicate delivery and a success, and `409` is a claim that is really gone.
And a renew's two failures are different failures over a WAN — `applied: false` means the claim is
gone and the runner halts, a transport error means almost nothing and the runner keeps playing,
because the clamp above leaves ~10× the renew interval of headroom and a lost claim is refused at
finish anyway.

**The finish gained three misconfiguration gates, and one was specified wrong.** The engine digest
played must equal the row's; strikes must be within `matches.strike_ceiling`; ranks must be within
`1 <= rank <= 2 × seat_count`. The proposal said ranks must be *a permutation of `0..seat_count-1`*,
and Ants ranks from 1 and allows ties — `{1,1}` is the commonest two-seat result — so that gate
would have refused most real matches. A fourth gate, `turns` within `max_turns`, was specified and
**not built**; §5 has it.

### The submission path

| # | Question | Decision | What it overturns, and what it cost |
|---|---|---|---|
| N12 | Is a GitHub **release** still required per version? | **No.** `model_versions.release_tag` and `commit_sha` are deleted, along with jodi's `commit` task, the `jodi-github` connector and `release_base` | Nothing verified it. `release_tag` was a string in a unique index that did not care whether a release existed, and the commit read was `continue_on_error`. The platform asked competitors to publish something it never checked |
| N13 | Is a GitHub **repository** still required per entry? | **No.** `models.repo`, `owner_github_id`, `owner_login`, `repo_path()`, `season_admits_repo()`, the `repo` rules block and two unique indexes are deleted. GitHub is the sign-in identity and nothing else | **57, 58 and 59**, which are the ownership check and its two repairs. They were right about the mechanism and wrong about the field: every ceiling on a competitor is a season rule and none of them mentioned a repository, so the guard policed something that limited nothing — while failing closed, which meant a rate-limited GitHub stopped anyone creating an entry. Removing the field removed the problem class instead of defending it, and with the `repo` block went the one rules block whose `enabled` defaulted true |
| N15 | How is an entry addressed, once the repository is gone? | **By id: `GET`/`PATCH /v1/models/{id}`**, the shape `/v1/matches/{id}` and `/v1/versions/{id}` already use | `/v1/games/{game}/models/{owner}/{repo}`. The alternative was `{owner}/{name}`, which would have made `models.name` part of a URL and so needed a slug charset on a column that is a competitor's own words. An opaque id keeps `name` free text and per-owner-unique — two competitors may hold one name, because a name is not an identity |
| N16 | What labels a submission, with no release tag? | **`version`, the per-entry counter the insert already assigned** | A competitor-chosen `version_tag` was the other option and is what the proposal made it. `model_versions_model_version_uniq (model_id, version)` already existed, so the counter was doing the work either way; a free-text label would have been a second key that could disagree with the first |

### The clocks' repository

| # | Question | Decision | What it overturns, and what it cost |
|---|---|---|---|
| N19 | Are the clocks a repository and a package of their own? | **No. `jodi` merges into `soma`**: the four clocks, `tb-probe`, `tb.rating` and `tb.pairing` load as part of the soma package under their existing ids, from `soma/scripts/gen-clocks.py` and `soma/plugins/`, and **the `jodi` role goes** — the clocks run over `soma-db` as the owner, which pools 20 | Architecture §1's "the day Soma's REST surface must scale independently of the match maker, Jodi gets its own service and neither repository changes". That day never came: the two always loaded into one Orion and one `[vars]` block, and 17 of jodi's 30 commits had a same-day twin in soma. The boundary cost a copy of every loader and check script, and jodi's `check-sql.sh` had stopped seeing 14 of its 23 statements. **Cost:** a clock that deletes, reads `sessions` or rewrites an entry is caught by review, not by a grant. A future split of servers is a second package compiled from one repository |

---

### A season's boards, and its name

Taken and built 19 September 2026. The design and the three rounds of calls that shaped it are
[`season-maps.md`](season-maps.md); what it changed in each repository is in their Status blocks.

| # | Question | Decision | What it overturns, and what it cost |
|---|---|---|---|
| N28 | Where do a season's boards come from, and what is a season called? | **A season's boards are uploaded to it, one file at a time, by an admin, and are in no repository and no release.** An upload is judged by the engine's own `worldgen` on Soma's node (which now loads `tb.ants`), checked against the cartridge's `limits.boards`, stored **disabled** in `season_maps` and **public** from that moment; an admin enables and disables boards at any time before the close, and a board is **never deleted**. Disabling cancels the matches queued on it and lets claimed and running ones finish and count. Pair reads the season's enabled boards on every run, and the board **rides the claim**. **Presets are gone**: the component carries no boards (`build.rs` is deleted) and `worldgen` requires the board whole. **The release ships five basic boards**, one per size and two to eight seats, which define `limits.boards` and are what admission's reference set is drawn on, so a model admitted today can play any board a season adds later. **A season has a name** ("Summer 2026"), fixed at creation, and **its slug is its only address** -- in every URL, route, query and notification; `number` is an internal ordinal | **N27**'s *one board a preset* and the 17 September rule that a board is an engine-digest change, travelling on the same rails as a rules change: that made a season's boards the deployed engine's, so a new board was a new engine, refused under a live season and claimed by no replica on the old one. Packages -- a content-addressed set of boards per season, shipped in the ants release -- were the first design and were dropped for uploads. **Cost:** a live season's standings are earned on whichever boards were enabled at the time, which only `season_map_events` records; the envelope is whatever the basic boards span, so a season wanting a 128-a-side board needs a new basic board and an ants release first; Soma's image now carries and signs the component; and a board's reason for refusal reaches a workflow only as a code, so the admin reads it from `tinybrains maps check` |
| N29 | Where do a season's baselines come from, and does the platform ship a model? | **A season's baselines are uploaded into it by an admin, and the platform ships no model.** The admin names one and gives its two files; `POST /v1/games/{game}/seasons/{slug}/baselines` records a `testing` version of the account `baseline.<slug of the name>` (made if new, with its one entry) and answers two presigned PUTs, as a submission does, and **the admit clock admits it by the same walk** -- the node fetches and re-hashes the bytes, reads the graph, runs the adapters over the reference observations and measures the class -- then lands it **`disabled`**, a new `model_status` that is a baseline's alone: admitted, no trial, out of play. `PATCH .../baselines/{slug}` `{"enabled": bool}` moves it to `active` and back: the first enable seeds its two ratings at the season's prior with their seq-0 events (placement, decision 28), a re-enable keeps them, and a disable cancels its `pending` matches (`BASELINE_DISABLED`) while running ones finish and count; both bump the roster epoch and write `baseline_events`. **Disabled is off the ladder** (every reader of `active` leaves it out) with its rating and matches kept. **A new season starts with none**: season create no longer carries baselines, a name used again is the same account with a new version, one name holds one version a season (an upload admission rejected frees it), and one set of weights may stand under several names. `GET .../baselines` is the admin's, because an upload being admitted or refused is nobody else's. **Removed:** bootstrap's baselines step (`docker/baselines.py`, the image's and web's `baselines.toml`, `BASELINES_CONFIG`/`BASELINES_FILE`) and the three models committed in `ants/baselines/models/`, which moved to `ants-starter/models/` for testing against; ants' conformance test loads the starter's micro-bc | The roster (18 September 2026): a TOML file bootstrap read, whose models it downloaded by pinned URL from an ants commit, trusted a `metrics.json` for (checked hashes, measured nothing), uploaded with hand-signed SigV4 and seeded as live-season versions -- so a baseline was a deploy step, its weights lived in a code repository, and changing one meant a commit, a re-pin and a bootstrap. It also retired the **carry**: season create copied the previous season's baselines as new version rows whose generated bucket keys were empty, so from season 2 no runner could play one (13 of 13 404s, found building the roster); only a bootstrap restored them. **Cost:** a new season pairs no trial until an admin uploads and enables its baselines, so a candidate waits; an upload races the admit clock exactly as a submission does, and one the clock reaches before its PUT lands is rejected `ARTIFACT_MISSING` and uploaded again; and a season's baselines are admitted under its own graph and class rules, so a season offering only `nano` cannot hold a micro baseline |

## 5. Still open

| # | Decision | Forced at | Note |
|---|---|---|---|
| 30 | λ for the TinyBrain Index | public launch | fit after season one, or publish a provisional value so competitors have something to optimise against from day one. `seasons.lambda` is gone; `standings.lambda` in the rules document is its home |
| 31 | Shared trust root for cartridge and platform plugins | public launch | one key serves both units today; `public_keys` is a per-unit list, which is what keeps this free to go either way |
| — | Scheduling a season ahead | owner's call | as built, the next season is created only after the previous closes, so nobody can announce "season 4 opens on the first" while season 3 settles |
| — | The king match | pairing | one match of a placement burst against the current leader of the version's class ladder, as pairing's answer to a stale top |
| N14 | Rename `manifest.json` to `adapter.json`? | — | **Kept unless overruled.** The document declares `abi`, `inputs` with their adapters, `outputs` and `probe_dims`, so `adapter.json` names a part for the whole, and the rename reaches `manifest_key`, Orion's registration and every page of the book |
| — | A turn bound in the finish | soma | The fourth misconfiguration gate (§4b). Not a one-predicate change like the other three: `max_turns` is a season rule since N18, not a `matches` column, so the finish needs the claim's own coalesce. `runner_gate` already reads the two columns it would join |
