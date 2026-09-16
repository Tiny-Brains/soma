# Admission

The fourth clock. A competitor `POST`s a release; `tb-admit` verifies it and either hands it to
pair for a trial or rejects it with a reason. **The clocks are therefore the version's whole life
cycle**, not just the match maker: admit verifies, pair gives the trial, count decides it and promotes,
withdraw sweeps what a promotion left behind.

The clocks that surround this one are [`clocks.md`](clocks.md) and the numbers are
[`config.md`](config.md). The entity it drives is Orion's own `models`, on the node the clocks run on —
there is no loader service any more, and `devops/docs/decisions.md` (the R-series) is why.

## 1. What this page fixes

| Settled here | Left to |
|---|---|
| the admission channel: schedule, singleton key, timeout, tracing | 07 the schedule at N submissions a minute |
| **decision 20** — the verification timeout, the attempt cap, and what a timeout means | — |
| **decision 35** — the competitor declares both hashes at submit | — |
| the claim: how one run takes a submission and no other run touches it | — |
| the walk — release metadata, the two objects, registration, admission, the probe, the verdict | — |
| the policy applied to the node's facts: class, opset, op allowlist, parameters | 06 the opset pinned per season |
| the two-class split: what rejects a version and what merely retries | — |
| the rejection vocabulary, every word actionable by a competitor | — |
| the game's registration: the manifest and the reference observation set | 05 generating Ants' reference set |
| the re-validation sweep when the Orion version changes — finding 5 | — |
| what Soma tells a competitor at each of the five statuses | web the screens |
| the numbers, in the clocks' section of Soma's `[vars]` block | 06 finalising them against real submissions |

---

## 2. The shape: a fourth clock

```
tb-admit   every 20 s   singleton key `admit`   →   tb-admit-run
```

One cron channel, one workflow, and the same generated-from-Python shape the other three have. It
lives in `scripts/gen-clocks.py`, it is checked by `scripts/check-defs.sh` and `scripts/check-sql.sh`,
and it loads under `pkg:soma` with the rest of the package.

**What being one of the clocks means, in four consequences.**

1. **It uses `soma-db`.** No database connector of its own and no grants: the clocks run as the
   schema owner, and count's promote and reject statements already update `models`.
2. **Its numbers join the clocks' section of Soma's `[vars]` block**, `CLOCKS` in
   `soma.toml.tmpl`. §11.
3. **It brings three connectors of its own**: `soma-node-admin` for this node's admin API,
   `soma-models-internal` for the models bucket, and `soma-models-http` for reading a presigned URL
   back. Kalam's roster clock has its own pair, pointing at its own node.
4. **The clocks reach no host outside the deployment.** It used to reach exactly one — GitHub's API,
   for the commit a release tag pointed at — and that task is deleted along with the release it
   read. The artifact is read from the platform's own bucket by a node that re-hashes it, and
   nothing on the platform downloads from a competitor's host: **the competitor uploads**, which
   is what let the fetch allowlist be deleted rather than tightened. There was a `jodi-github`
   connector, and it went with that task; `soma-db` and the three above are the whole list.

**Why not a repo of its own.** It was offered and refused, and the refusal is right: admission
shares count's tables, its server and its clock idiom, and a repo of its own would buy an isolation
nothing is asking for. The repo split earns its keep where two packages have different *deployment*
needs; admission and count have the same one.

**Why not inside Soma** — *the argument as it was made, before the clocks were Jodi's own repository;
superseded 16 September 2026.* Soma's package was eleven REST channels and no clock. A cron channel in
a cluster-mode server needs the singleton lock and the misfire policy that Soma otherwise never used,
and a long-running verification inside the server that serves the API is the wrong thing to put
there. **What happened instead:** Soma grew a cron channel of its own (`soma-runner-reap`), Jodi was
always loaded into the same server as Soma, and the reasoning in the paragraph above — the split
earns its keep only where the *deployment* differs — applied to Jodi and Soma exactly as it applies
to admission and count. The long-running verification still runs in the server that serves the API;
that it could be moved is a package split, not a repository one.

### 2.1 The channel

```jsonc
{ "channel_id": "tb-admit", "workflow_id": "tb-admit-run",
  "tags": ["pkg:soma"], "channel_type": "async", "protocol": "cron",
  "transport_config": {
    "schedule": "*/20 * * * * *", "timezone": "UTC",
    "misfire_policy": "latest",
    "concurrency": { "policy": "forbid", "key": "admit" } },
  "config": { "timeout_ms": 600000,
              "tracing": { "errors_only": true, "task_details": true } } }
```

- **Every 20 s**, because a competitor is watching a page. Pair runs at 15 s and count at 10 s;
  admission is the slowest of the four because a run of it can take minutes and there is nothing
  behind it that a second's delay costs.
- **`forbid` on key `admit`** — one admission run in the cluster at a time. Note what this does
  *not* buy: it is an optimisation, exactly as the other three clocks' locks are, and §4's claim is the
  correctness.
- **`timeout_ms` is 600 000** and is deliberately far above §4's per-submission `admit_timeout_s`.
  The channel timeout bounds a *run*, which is up to `admit_batch` submissions; the per-submission
  timeout is what makes a stuck one retryable. Confusing the two is how a batch of four small
  models gets killed because the first was large.
- **`errors_only` tracing** from day one, as [devops/docs/architecture.md](https://github.com/Tiny-Brains/devops/blob/main/docs/architecture.md) §7 requires of every
  cron channel. A submission's trace is a competitor's release URL and their adapter; it is not
  something to keep by default.

---

## 3. What the competitor declares — decision 35

**The competitor declares both hashes at submit, and admission refuses bytes that do not match.**

`POST /v1/submissions` is the entry and the two hashes, and nothing else:

```jsonc
{ "game": "ants", "model": "9f3c1a7e-…",
  "weights_hash": "sha256:…", "manifest_hash": "sha256:…" }
```

and `soma-submissions-create` writes them onto the `testing` row at insert — and then answers with
two one-shot presigned PUT URLs for the competitor to upload the two files to.

**The declaration is now load-bearing rather than merely useful, and the reason changed with the
upload.** When the platform fetched a release, the declaration was a check on something it could
have computed itself. Now the platform receives whatever is PUT to a URL it signed, and the
declaration is what says whether that was the right thing. It is checked twice, in two places, by
two different processes: the node re-hashes the artifact against `artifact.digest` at admission, and
Postgres re-hashes the manifest against `manifest_hash` both in `manifest_ok` and in the
`model_versions_manifest_matches_hash` constraint.

Three things it buys:

- **A competitor can verify what was admitted.** They computed the hash on their own machine. If
  admission accepts, the platform holds their bytes and not something else's. Without the
  declaration the platform records a hash it computed itself, which a competitor can only check
  *after* the fact and only against a number the platform chose.
- **It pins the bytes across a retry.** §4 gives verification a timeout and up to
  `admit_attempts_max` attempts, and each attempt re-reads the object. An object replaced between
  attempt one and attempt two would otherwise mean attempt two admits bytes that attempt one did not
  inspect — silently, with no way to notice.
- **It makes an upload URL safe to hand out.** A signed PUT is a capability, and what stops it
  becoming a way to put arbitrary content on the platform is that anything whose digest is not what
  was declared is refused at admission, by the node, naming the hash it measured.

The cost is two lines in the documentation:

```sh
sha256sum model.onnx manifest.json
```

and it is what a CLI would send anyway (the build).

**What is not decided here.** Whether Soma should *compute* the hashes for a competitor who pastes a
release URL into the Submit screen is a web-track question. The API takes the declaration; how a
screen helps someone produce it is the screen's problem.

### 3.1 The two assets — decision 17 applied

Decision 17 fixed the canonical names: `model.onnx` and `manifest.json`. They are the names on the
upload URLs Soma signs and the leaves of the two object keys:

```
models/{version_id}/model.onnx
models/{version_id}/manifest.json
```

There used to be a second pair above these — a `{release_base}{repo}/releases/download/{tag}/…`
URL per asset, described as the public record. It was never fetched, never verified, and is gone.

**The bucket keys are a GENERATED column, not a construction.** `model_versions.artifact_key` is
`'models/' || id::text || '/model.onnx'`, computed by Postgres and never written, so the three
readers of a version's bytes — Soma signing the upload, the admit clock at admission, and every replica's
roster clock — cannot disagree about where they are. A key derived from a hash, which is what the
loader did, made the hash a path; this one cannot be.

**The artifact IS the audit trail.** The public-read models bucket holds the exact bytes under
`models/{version_id}/model.onnx`, a GENERATED key nobody can delete or retag, beside the stored
manifest — a stronger record than a repository that might be empty and a release that might be
gone. The old argument here was that a release was "still required, because a leaderboard entry
nobody can audit is not an entry"; nothing verified it, so it audited nothing.

**What used to be here.** An `AXON_FETCH_ALLOW_HOSTS` of exactly
`github.com,objects.githubusercontent.com`, on the one process that was allowed to reach the public
internet, so a redirect anywhere else was a refusal rather than a fetch. The upload flow deleted
that whole surface: there is no process with an allowlist because there is no process that
fetches.

---

## 4. The claim, the timeout, and the attempt cap — decision 20

### 4.1 The claim is the fence

Count claims a run fence in `clocks` because count is the only writer of a ladder and must prove a
stale occurrence wrote nothing. **Admission needs no run fence**, and saying why is worth a
paragraph, because the absence is the design.

Admission writes exactly one thing: the `models` row it has claimed. The claim is one conditional
`UPDATE` returning `rows_affected`, so two concurrent runs cannot both take the same submission —
the loser is told it affected nothing and skips the item. There is no cross-row invariant to hold
and no ordering to preserve, which is what a fence is for. **The claim *is* the mutual exclusion,
and it is per row rather than per run**, which is strictly better: a run that dies halfway through a
batch releases the submissions it had not reached at once, and the one it was verifying after its
timeout.

### 4.2 The three numbers

| | | |
|---|---|---|
| `admit_batch` | **4** | submissions a run may take |
| `admit_timeout_s` | **180** | how long a claimed submission stays claimed before another run may re-claim it |
| `admit_attempts_max` | **3** | attempts before the submission is rejected `TIMED_OUT` |

**Why 180 s.** The compression that used to dominate this number is gone with the old size metric:
`S'` is `artifact_bytes + length(manifest)`, which is a `HEAD` and a `length()`. What is left is
the object fetch from the bucket, a SHA-256 over it, an ONNX parse, a tract plan build, five probe
inferences, and then `tb-probe` over the reference set. At the top of the `Large` class that is a
100 MiB read and a graph build; at Micro it is milliseconds. 180 s is a bound with room in it
rather than a guess, and the room is mostly the graph build, which is where tract's optimiser
spends its time. It is provisional and it is in `[vars]`; the thing that moves it is the first real
`Large` submission.

**What the timeout covers, and finding 6d.** It covers *verification only*. A `verified` version
then waits for its trial, and **a trial row never times out the candidate** — the trial is an
ordinary match row that pair inserts and Kalam claims first, and if it fails to play, count's
verdict logic re-pairs it up to `repair_cap` times before refusing it as `UNPLAYABLE`
([`clocks.md`](clocks.md) §5). Two separate clocks with two separate patiences, and neither can
strand a version in the other's.

**Three attempts, then `TIMED_OUT`.** A submission that has been claimed three times without
reaching a verdict is rejected, with `TIMED_OUT` as the reason a competitor reads. It is the one
rejection word that does not mean "your model is wrong", and the Version screen says so: it means
the platform could not finish checking, and the fix is to submit again. Three, rather than
unbounded, because a submission that reliably hangs the loader is a submission that would otherwise
hold a claim slot every 180 s for ever.

### 4.3 The claim statement

```sql
-- Take up to $2 submissions that are unclaimed or whose claim has lapsed, stamping this run's
-- occurrence on each. rows_affected is the number actually taken; the document below reads them
-- back by that stamp, so two runs racing cannot both proceed on one row.
UPDATE models m
   SET admit_started_at = now(),
       admit_attempts   = m.admit_attempts + 1,
       admit_token      = ($1)::uuid
 WHERE m.id IN (
         SELECT c.id FROM models c
          WHERE c.status = 'testing'
            AND (c.admit_started_at IS NULL
                 OR c.admit_started_at < now() - (($3)::int * interval '1 second'))
          ORDER BY c.created_at
          LIMIT ($2)::int
          FOR UPDATE SKIP LOCKED)
```

`SKIP LOCKED` for the same reason the match claim uses it: two runs that overlap take disjoint sets
rather than one blocking on the other. `ORDER BY created_at` so the queue is fair, and so a
submission that has already burned an attempt does not jump ahead of one that has not.

The attempt cap is applied *before* the walk rather than in this statement, so that the third
attempt is recorded and the rejection names it:

```sql
-- Reject what has run out of attempts. Runs once a run, before the claim.
UPDATE models
   SET status = 'rejected', reject_reason = 'TIMED_OUT'
 WHERE status = 'testing' AND admit_attempts >= ($1)::int
   AND (admit_started_at IS NULL OR admit_started_at < now() - (($2)::int * interval '1 second'))
```

---

## 5. The walk — `tb-admit-run`

The same loop shape count uses: one document of work read on sweep 0, then one item per sweep,
`loop.max` a bound and the `more` filter the terminator.

```
     token       a fresh uuid for this run's claim                          map        sweep 0
  0  expire      reject what has run out of attempts                        db_write   sweep 0
  1  claim       take up to admit_batch testing rows                        db_write   sweep 0
  2  batch       read the claimed rows, with the game's manifest and refs   db_read    sweep 0
  3  more        stop when the work runs out                                filter
  4  item        take item i, and clear every slot the last one wrote       map
  5  head        HEAD the artifact key in the models bucket                 storage_head
  6  sign        presign a 5-minute GET for the manifest key                storage_presign
  7  fetch_text  the manifest as the bytes that were uploaded               http_call
  8  fetch       the same object, parsed                                    http_call
  9  manifest_ok does it hash to manifest_hash? and how long is it?         db_read
 10  shape       the registration, rebuilt field by field                   map
 11  reject_result  a manifest may not decode its own head                  map
 12  register    POST /models { manifest, artifact: {connector,key,digest} } http_call
 13  admit       POST /models/{id}/admit?wait=true                          http_call
 14  sift        passed, refused, or unreachable -- whose fault?            map
 15  activate    PATCH /models/{id}/status  active                          http_call
 16  probe       channel_call tb-probe over the reference observations      channel_call
 17  pd          what the probe bound each named axis to                    map
 18  metric      S' = artifact_bytes + len(manifest)                        map
 19  classify    which class does S' measure into, in THIS version's season db_read
 20  judge       class, opset, operators, parameters, the budget            map
 21  archive     PATCH /models/{id}/status  archived                        http_call
 22  verify      testing -> verified, with everything learned               db_write   if pass
 23  reject      testing -> rejected, with the reason word                  db_write   if fail
 24  giveback    release the claim and give the attempt back                db_write   if our fault
```

**Twenty-six tasks as built.** Every task from 5 onward runs for one submission, and `item`
clears every per-item slot as it takes the next one, because `temp_data` survives a loop sweep and
a stale `head` or `admitted` would decide the wrong row's verdict.

Nothing in the walk touches another row, another table, or a rating.

**There is no loader, and the change is structural rather than cosmetic.** Admission is now Orion's
own `models` entity, running on the node the clocks run on: a model row is a manifest plus an artifact
reference — `{connector, key, digest}` — and the node fetches the object through a storage
connector, re-hashes it against the digest, reads the graph from the protobuf, and runs five probe
inferences over zero-filled inputs. The admit clock does not fetch a competitor's bytes, and neither does
anything else on the platform: **the competitor uploads them** to a presigned PUT that Soma minted
at submission (decision R11), which is what let the admission service, its fetch allowlist and its
mirror step be deleted rather than ported.

### 5.1 The batch document — task 2

One read, returning everything the walk needs so that no later task queries again: the version's
identity and declared hashes, its `artifact_key` and `manifest_key`, the game's `adapter_ops_max`
and reference observations, and — from **the version's own season** — the graph rules the verdict
is judged against. `rules_ok` rides with them, because without it a null ceiling reads as "no
ceiling" through `{"<": [x, null]}`, which is falsy: every submission would pass every gate, in
silence.

**The budget comes from the game's manifest, not from `[vars]`.** `adapter_ops_max` is the
cartridge's declaration ([*Adding a game*](https://github.com/Tiny-Brains/web/blob/main/docs/src/platform/adding-a-game.md), the registration manifest) and it is per game by construction —
a 128×128 Ants board and a card game have nothing in common. Putting it in the clocks' config would make
a second cartridge a config change; putting it in the game row makes it content. §8 says how it
gets there.

**The reference observations come from the game row too**, and they are the reason §8 exists at all.

**The rules come from the version's season and not from the live one**, which is what lets §9's
re-validation sweep judge an older version by the rules it was admitted under.

### 5.2 The two objects — tasks 5 to 9

**`head` before anything else.** `storage_head` on `artifact_key` answers whether the graph is in
the bucket at all; nothing is fetched. Absent, the walk stops at `sift` with `ARTIFACT_MISSING` and
the exact key it looked under.

**The manifest is fetched twice, deliberately.** `storage_presign` signs a five-minute `GET`, and
then two `http_call`s read the same URL: `fetch_text` with `response_format: "text"` for the exact
bytes that were uploaded, and `fetch` for the parsed document. The bytes are what
`manifest_ok` hashes and what `models.manifest` stores; the document is what the registration is
rebuilt from. One call cannot serve both — a parsed reply has already lost key order and
whitespace, and the stored form would no longer hash to `manifest_hash`.

> `http_call` always prefixes its connector's base URL onto `path`, so a presigned URL cannot be
> used as-is: `substr(url, length(models_endpoint))` reduces it to a path, which is exact only
> because the storage connector sets `force_path_style`. Same trick as Kalam's replay PUT.

**`manifest_ok` is a `db_read` and that is the point.** Postgres computes
`sha256(convert_to(text, 'UTF8'))` over what arrived and compares it to the declaration, and returns
`length()` beside it — the second term of the weight class, measured in the same breath. The
schema's `model_versions_manifest_matches_hash` recomputes exactly the same expression, so a
mismatch that reached `verify` would be a constraint violation: a 500 and a burned attempt for what
is an ordinary competitor mistake. Checking it here turns it into `MANIFEST_MISMATCH`.

### 5.3 The registration — tasks 10 to 13

**`shape` rebuilds the registration field by field rather than forwarding what was uploaded**, and
the reason is the model id. An Orion label may not begin with a digit, so a version's uuid is
refused and the id is `tb.v<uuid>` (decision R9) — and the id a registration takes is the
manifest's own `name`. Forwarding the competitor's document would register every entry under
whatever name they wrote in it, and two competitors would collide. `shape` takes `abi`, `inputs`,
`outputs`, `version`, `format`, `description` and `probe_dims` from the document and **forces
`name`**.

**`reject_result` refuses a manifest carrying a `result` expression.** The head is the platform's
(decision R3): a `result` expression's root is the output tensors alone, so it cannot see the
observation and cannot gather at the ants' cells, and the channel order is a rule of the game
rather than the entrant's choice. A manifest that tries is `RESULT_NOT_ALLOWED` — said plainly,
because silently ignoring it would let a competitor believe their decode ran.

`register` then `POST`s `/models` with the manifest and `{connector, key, digest}`, and `admit`
`POST`s `/models/{id}/admit?wait=true`. **That one call does what `/load` and `/inspect` used to
do between them**: it fetches the object through the connector with a signed GET, verifies the
digest, reads the graph from the protobuf — parameters, nodes, operators, IR version, opset — and
runs five probe inferences at `probe_dims`, whose median must land within `models.max_probe_ms`.
Its stages are `signature, gate, head, size, fetch, digest, cache, parse, probe`, and a refusal
names the one it failed at, which `sift` upper-cases into `<STAGE>_FAILED`.

> **Every admin reply is wrapped in `{"data": …}`**, so this walk reads
> `temp_data.adm.data.admission.state` and not `temp_data.adm.admission.state`. Read through the
> wrong one and `null != "passed"` is TRUE, and every submission is refused with a stage word it
> never produced. It cost an afternoon; `orion-notes.md` §0 has it.

### 5.4 The probe — tasks 15 to 18

Admission's probe runs the graph on **zero-filled** inputs, which proves it loads and times it, and
says nothing about whether the manifest's adapters can shape a real observation. That is what
`tb-probe` is for: `activate` makes the model servable on this node, and a `channel_call` runs
`model_infer` over each of the cartridge's reference observations under the game's own
`adapter_ops_max`, asserting that every one produces a decodable action.

What comes back that this page acts on:

- **`ok: false` with a `reason`** — mapped through §7's vocabulary, with the failing case index kept
  for the competitor. `over_budget` is distinguished from malformed, because "too expensive" and
  "invalid" must not read the same word.
- **`ops_max`** — the heaviest single evaluation, recorded so the Version screen can show how close
  a competitor is to the ceiling.
- **`infer_us_max`** — the slowest reference case's inference, in microseconds. **Recorded, never
  judged.** There is no compute cap (decision 46): the class comes from `S'` alone, and a graph too
  expensive to play runs into the *turn deadline*, at play, as its own strike. Each seat gets its own
  `model_infer` with its own `timeout_ms`, so one slow graph cannot spend another's.

**`pd` records what the probe bound each named axis to.** A dimension may be a name, so `infer_us`
is not comparable between two versions without knowing the size it was measured at (decision R2).
`stats.probe_dims` is that, and it lands in `model_versions.probe_dims`.

**The requirement this page cannot enforce and depends on anyway**: the reference set must contain a
worst-case observation — the largest preset, the most units. The budget is checked *per evaluation*
during a real match, so an adapter probed only against a small sample and then struck on every turn
has been admitted by a gate that did not test it, and the competitor finds out by forfeiting. §8 is
that requirement's answer.

### 5.5 The judgment, the archive, and the verdict — tasks 18 to 24

**The node reports facts; this page judges them**, and the split is deliberate: a threshold change
is then a platform decision and not a redeploy of anything.

| Fact | Judged against | Rejection |
|---|---|---|
| `S'` = `stats.artifact_bytes` + `length(manifest)` | the version's season's `weight_classes` | `TOO_LARGE`, or `CLASS_NOT_OFFERED` |
| `stats.opset` | `opset_min` … `opset_max` | `OPSET_UNSUPPORTED` |
| `stats.operators` | the allowlist, intersected with the season's | `OP_NOT_ALLOWED`, naming the offenders |
| `stats.parameters` | `graph.params_max`, where a season sets one | `PARAMS_EXCEEDED` |
| the probe's verdict | the game's `adapter_ops_max` | `ADAPTER_OVER_BUDGET` / `ADAPTER_INVALID` |
| `stats.nodes`, `ir_version`, `infer_us` | nothing — recorded and displayed | — |

**`S'` replaced a metric that could be understated.** The old `S` compressed `GraphProto.initializer`
and the adapter file; a graph carrying its trained weights as `Constant` node attributes measured as
nearly nothing and landed in a class it did not belong in. `artifact_bytes` is the whole file,
measured by the node against a digest it re-hashed, and `length(manifest)` is measured by Postgres
over the bytes that were uploaded. Neither term can be understated by where a weight sits. The class
caps doubled with the metric, because `S'` is raw where `S` was compressed.

**`stats.operators` is why the allowlist check survives the rewrite.** Orion 1.8.1 records the
distinct operators a document uses — sorted, domain-qualified, over subgraphs and model-local
functions — and records them without gating on them, which is the right division: the probe answers
"does this run here" and the list is policy. The clocks hold ~40 names in `[vars]`, **intersected** with
the season's rather than replaced by it, and rejects on set difference naming what it found.
"`ScatterND` is not allowed" is actionable; "your model uses an operator this platform does not run"
is not.

**The class is derived here and written once**, against the version's own season's table, smallest
cap that fits. It is a statement rather than a JSONLogic reduce because `reduce` binds `current` and
`accumulator` through the `val` operator only, so a `var` inside one yields null — a wrong class
that looks like an absent one — and because the ascending-order rule the pick depends on is already
a CHECK on the column. `open` is not assignable and the schema refuses it
(`model_versions_weight_class_not_open`).

**`archive` leaves the admission node's active set empty**, and it is hygiene rather than
correctness: exactly one version of a model id may be active at a time, and the next submission
from the same competitor registers a *different* id. What it buys is a node whose model list is not
a growing record of every entry ever admitted.

The verdict is one statement, and it is the statement pair has been waiting for since the build:

```sql
-- testing -> verified. Everything the node learned, written once, under the claim.
UPDATE model_versions
   SET status = 'verified', weight_class = ($2)::ladder,
       size_bytes = ($4)::bigint, param_count = ($5)::bigint,
       infer_us = ($6)::bigint,
       manifest = ($7)::text, orion_version = ($8)::text,
       probe_dims = ($10)::jsonb,
       admit_started_at = NULL, reject_reason = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($9)::uuid
```

and its twin:

```sql
UPDATE model_versions
   SET status = 'rejected', reject_reason = ($2)::text,
       admit_started_at = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($4)::uuid
```

Three things about the pair:

- **`AND admit_token = …`** is the claim honoured at the write. A run whose claim lapsed while it
  was verifying — because it took longer than `admit_timeout_s` and another run re-claimed the row —
  affects zero rows and writes nothing. It does not halt the run: the item is simply lost to the run
  that now owns it, which will redo the work. That is the correct outcome and it is why the timeout
  can be generous without being dangerous.
- **`model_versions_past_testing_has_contents` is what makes this safe.** The schema refuses a row
  past `testing` without `weights_hash`, `manifest_hash`, `orion_version` and `weight_class`, so a
  verdict statement that forgot one is a constraint violation and not a half-verified version that
  pair happily seats.
- **`manifest` and `manifest_hash` cannot disagree**, because
  `model_versions_manifest_matches_hash` recomputes the hash over the stored text. That is why
  task 8 fetches the manifest as *text* — the bytes that were uploaded, not a re-serialisation of
  the parsed document.

**`orion_version` replaced `evaluator_digest`**, which named a build of a service that no longer
exists. What actually prices an adapter now is datalogic, at the version the node links, and
datalogic's own documentation says the operation count is not stable across versions. So the sweep
in §9 is per Orion upgrade rather than per dialect change — a coarser trigger, and an honest one.

**Nothing here bumps the roster fence.** `testing → verified` does not change who is contesting: a
`verified` version contests only as the candidate seat of a trial row, and pair inserts that row
under the fence itself ([schema.md](schema.md) §6.2). Promotion is where the fence
moves, and promotion is count's.

**And a version verified here is not yet playable anywhere.** Models are a per-node entity and each
Kalam replica is its own Orion, so each replica's own `tb-roster` clock registers, admits and
activates it from `model_versions`. No clock calls a replica: the database is the only channel
(decision R8). A replica that has not caught up releases the row rather than playing a seat blind.

---

## 6. What rejects a version, and what merely retries

**The two-class split, which the whole platform branches on.** Kalam's match clock releases a row
on a fault that is the platform's and fails the seat on one that is the model's. Admission branches
the same way, for the same reason, and `sift` is where it happens: `temp_data.reason` is set when
the competitor's submission is wrong, `temp_data.retry` when the platform could not check it, and
never both.

| Class | Means | Admission does |
|---|---|---|
| a reason | the competitor's submission is wrong | **rejects**, with the reason word (§7) |
| a retry | the platform could not check it | **releases the claim**, and does not spend an attempt |

Orion's own admission reports a **stage** — `signature, gate, head, size, fetch, digest, cache,
parse, probe` — rather than a fault class, and this page assigns the class: a refusal that names a
stage is the model's (`<STAGE>_FAILED`), and a call that produced no answer at all is the
platform's (`ADMISSION_UNREACHABLE`). `ARTIFACT_MISSING`, `MANIFEST_MISSING`, `MANIFEST_MISMATCH`
and `RESULT_NOT_ALLOWED` are this page's own, decided before the node is ever asked.

**A released claim does not spend an attempt**, and the statement is separate from the claim for
exactly that reason:

```sql
UPDATE models SET admit_started_at = NULL, admit_token = NULL,
                  admit_attempts = admit_attempts - 1
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($2)::uuid
```

Decrementing rather than leaving the increment is what keeps `admit_attempts_max` a count of *real*
attempts. A store that is down for an hour must not consume a competitor's three tries.

**`ARTIFACT_MISSING` is the interesting one**, because it is the new competitor's most likely
mistake and it is not a fault at all: it means the submission was recorded and the two files were
never PUT to the URLs it answered with. It is a **reason** and not a retry — retrying cannot make
bytes appear — and the word has to read as an instruction. The Version screen says which key was
empty, and re-submitting the same release tag mints fresh upload URLs.

---

## 7. The rejection vocabulary

Every word a competitor can read, and every one actionable. This is the whole of what
`models.reject_reason` may contain from admission; count adds `FORFEIT`, `FAULT:*` and `UNPLAYABLE`
from the trial ([`clocks.md`](clocks.md) §5).

| Word | From | What the competitor does about it |
|---|---|---|
| `ARTIFACT_MISSING` | `head` | the bucket is empty at this version's key: **you did not upload**. Re-submit the same release tag for fresh URLs and `PUT` both files |
| `MANIFEST_MISSING` | `fetch` | the graph arrived and the manifest did not. The same fix, for the second file |
| `MANIFEST_MISMATCH` | `manifest_ok` | what was uploaded does not hash to what was declared — re-run `sha256sum` on the file you actually sent |
| `MANIFEST_INVALID` | `shape` | the document carries no `inputs` or no `outputs`. It is not an `orion:model@1.0.0` manifest |
| `RESULT_NOT_ALLOWED` | `reject_result` | the manifest carries a `result` expression. The platform reads the head (decision R3); delete it |
| `DIGEST_FAILED` | `admit` | the node re-hashed the artifact and got something else. The same fix as `MANIFEST_MISMATCH`, for the graph |
| `PARSE_FAILED` | `admit` | the ONNX parses but no plan builds — re-export it. A graph that indexes internally needs concrete spatial dims and cannot declare named ones |
| `PROBE_FAILED` | `admit` | it loads and will not run at `probe_dims`, or takes longer than the node allows for five inferences |
| `SIZE_FAILED` | `admit` | the object is past the node's ceiling before any class is considered |
| `TOO_LARGE` | `judge` | `S'` — the two files' bytes — is past the largest class this season runs |
| `CLASS_NOT_OFFERED` | `judge` | it fits a class, and this season does not run that class |
| `OPSET_UNSUPPORTED` | `judge` | re-export at an opset in the supported range |
| `OP_NOT_ALLOWED` | `judge` | the named operators are not on the allowlist; the message names them |
| `PARAMS_EXCEEDED` | `judge` | this season caps `stats.parameters` and the graph is over it |
| `ADAPTER_INVALID` | `probe` | an adapter did not produce a tensor the graph takes, or produced none for a declared input |
| `ADAPTER_OVER_BUDGET` | `probe` | over `adapter_ops_max` on the reference set; the detail carries the count and the failing case |
| `TIMED_OUT` | §4.2 | not your model — the platform could not finish checking; submit again |
| `MANIFEST_INCOMPLETE` | §5.1 | **never reaches a competitor**: a retry-class guard meaning the game has no manifest or no reference set. With no observations the probe would answer `ADAPTER_INVALID`, which would reject someone for the platform's omission — this is what stops it |
| `SEASON_RULES_INCOMPLETE` | `judge` | **never reaches a competitor** either, and for the same reason: a version whose season could not be read would have every ceiling null, every comparison falsy, and every submission passing every gate in silence |

**`<STAGE>_FAILED` is generated, not enumerated.** `sift` upper-cases whatever stage Orion's
admission stopped at, so a stage this table does not list still produces a word rather than a blank
— and the table is what the book publishes, not what the code can emit.

**Every rejection carries a `detail`** alongside the word: the failing case index, the operator
name, the two hashes, the byte counts, the stage. The word is what the Version screen shows; the
detail is what it shows when the competitor expands it.

**`ADAPTER_OVER_BUDGET` is a word of this page's, not of the engine's.** `tb-probe` answers with
`over_budget: true` for a budget overrun and a reason for a malformed program. Collapsing them would
tell a competitor whose adapter is merely expensive to go and re-read the operator reference. The
`judge` task splits them on `over_budget`.

---

## 8. The game's registration: the manifest and the reference set

`games` today is `slug`, `name` and `active_engine_digest`. The cartridge's declaration —
its registration manifest ([*Adding a game*](https://github.com/Tiny-Brains/web/blob/main/docs/src/platform/adding-a-game.md)) — lives nowhere, and admission needs two of them.

**`games` gains two `jsonb` columns**, and both are the *game's*, published by whoever wrote the
cartridge:

| Column | What it holds | Who reads it |
|---|---|---|
| `manifest` | the cartridge's declaration verbatim: `abi`, `game`, `version`, `presets`, `limits`, `budgets` | admission (`budgets`), and eventually pair (`presets`) instead of `[vars]` |
| `reference_observations` | an array of observations in the game's own state shape, **worst case included** | admission, and §9's sweep |

This is the shape a second cartridge takes without a schema change, which is the point: a new game
is a plugin in Kalam's package plus a row here, and its admission gate is content rather than code.

**What Ants owes, and now ships.** `ants/` generates `cartridge.json` from `engine/src/bin/manifest.rs`
rather than writing it — that is the `manifest` column — and it generates
`reference/observations.json` the same way: run the engine on the largest preset to a busy turn with
a committed seed, dump every live seat's view. Ten observations, deterministic, the game's own
rather than a loader fixture standing in for them, and a 128×128 worst case among them is what holds
`adapter_ops_max` at a million. The loader had one hand-dumped fixture; a set of one is enough to
admit a model and not enough to call the gate finished.

**Pair's presets stay in `[vars]` for now.** They could come from `manifest.presets` and eventually
should, but moving them is a change to a running clock for no gain this page needs, and
The general move of policy out of `[vars]` and into a `policies` table is tracked separately.

---

## 9. The re-validation sweep — finding 5

Every version records the `orion_version` that admitted it, and a change in it means the thing that
priced an adapter is no longer the thing that runs it. Finding 5 asks what happens to versions
admitted under the old one.

**Not a fifth clock, and not a pass that pulls models off the ladder.** It is the *tail* of the
admission run: when the batch of `testing` rows is empty, the run takes up to
`revalidate_batch` rows whose recorded version differs from the running node's and re-checks them.

```sql
SELECT … FROM model_versions v JOIN games g ON g.id = v.game_id
 WHERE v.status IN ('active', 'verified')
   AND v.orion_version IS DISTINCT FROM ($1)::text
 ORDER BY v.created_at
 LIMIT ($2)::int
```

The walk is §5's minus the GitHub call and minus the manifest fetch: the manifest is on the row, so
the registration is rebuilt from `model_versions.manifest` with no network, and `admit` and
`tb-probe` run exactly as before against the same reference set. **Holding the manifest bytes is
what makes that true**, and it is why §5.2 stores them rather than a reference to them.

- **Passes** stamp the new `orion_version` and change nothing else. A model that still validates
  is still admitted, and its rating is untouched.
- **Fails** are the interesting case, and the decision is: **reject, and let withdraw do the rest.**
  `active → rejected` with the reason word prefixed `REVALIDATE:`. The version stops contesting,
  The withdraw clock cancels its queued rows within the minute, and its history stays exactly as
  it was — the matches it played were played, and the clocks §5.3 already decided that the ladder
  records what was played.

**Why rejecting is right rather than harsh.** The alternative is a ladder containing versions the
platform can no longer run, which is a leaderboard that lies. The trigger is now `orion_version`,
which is coarser than the dialect digest it replaced — a patch release moves it whether or not
anything an adapter uses changed — and that is deliberate rather than sloppy: datalogic's own
documentation says the operation count is not stable across versions, so nothing finer would be
honest. What makes the coarseness affordable is that the sweep can now *measure* rather than
assume: `stats_output.ops` is recorded per call, so comparing one adapter's charge across two Orion
versions on the same observation says whether it moved at all.

**It is the second half of the clock and is built after the first walk.** §16 keeps it open.

---

## 10. What Soma tells a competitor

The five statuses, and the sentence each one is:

| Status | The competitor sees | Extra |
|---|---|---|
| `testing`, unclaimed | "queued for verification" | its place in the queue, if it is worth showing |
| `testing`, claimed | "verifying" | attempt *n* of 3 |
| `verified` | **"waiting for its trial match"** | the trial row once pair inserts it, and its queue wait |
| `active` | "on the ladder" | its class, its rating, its matches |
| `rejected` | the reason word as a sentence, and the detail | which of the two artifacts, and where |
| `superseded` | "replaced by v*n*" | a link to the successor |

**The stale-admission lockout is now the trial wait, and that is a change worth naming.** The old
design swept a submission that sat too long; nothing sweeps a `verified` version now, because
nothing needs to — it is not stuck, it is queued, and `models_one_in_flight_uniq` already stops the
competitor from submitting another while it waits. The fix is to **make the wait visible** rather
than to sweep it: the Version screen says "waiting for its trial match" and, once the row exists,
how long it has been pending. A wait a competitor can see is not a bug.

**What Soma changes.** `soma-submissions-create` takes the two hashes (§3); `soma-models-get` and
`soma-models-list` return `status`, `reject_reason`, `weight_class`, `size_bytes`, `param_count`,
`infer_us` and the trial row if there is one. Both are additive, and both are the web track's
to consume.

---

## 11. The numbers

`admit_batch`, `admit_timeout_s`, `admit_attempts_max`, `admit_deadline_ms`,
`revalidate_batch`, `opset_min`, `opset_max` and `op_allowlist` are in [`config.md`](config.md) §4,
with what moves each. The game's budget is not config: `adapter_ops_max` comes from
`games.manifest`, and the weight-class thresholds are the season's. There is no compute budget
(decision 46).

---

## 12. What admission must not do

- **It must not fetch a competitor's bytes.** Metadata from GitHub's API, yes; assets, never. The
  competitor uploads to a presigned PUT and the node reads from the platform's own bucket, so there
  is no process with a fetch allowlist because there is no process that fetches.
- **It must not write a rating, a match or a clock.** It writes `models`, and only the row it holds
  a claim on.
- **It must not promote.** `testing → verified` is the whole of its authority. `verified → active`
  is count's, in the run that decides the trial, and the seed comes with it (finding 3).
- **It must not bump the roster fence.** §5.5.
- **It must not judge inside the node.** Thresholds are policy; the node reports facts. Every
  number in §5.5's table is applied on this side of the seam, which is what makes a threshold change
  a platform decision rather than an upgrade.
- **It must not retry a model fault.** A rejection is terminal for that submission; the competitor
  submits again, which is a new row.

---

## 13. What admission asks of its neighbours

**Of Orion, nothing that is not already shipped.** The three things this section used to ask of the
loader were all answered by the rewrite rather than by a change: the manifest's exact bytes come
from the bucket rather than from an inspect reply, a missing object is a `storage_head` that
answers nothing rather than a fetch that has to be classified, and the budget/malformed split is
`tb-probe`'s, which is this package's own channel. What 1.8.1 added that this page depends on is
`stats.operators` — without it the allowlist check had no source once the loader went — and
`stats.probe_dims`, without which `infer_us` is not comparable between versions.

**Of the cartridge and `ants/`, one thing, and it ships.** A published reference observation set —
the largest preset, a busy turn, every live seat's view, from a committed seed. §8.

**Of the schema, nothing new** beyond §15's columns, which are additive and pre-release.

**Of `soma/`, two additive changes.** §3's two fields on the submit endpoint, and §10's fields on the
two model reads.

**Of `devops/`, no service and one bucket decision.** The admission service is gone; what replaced
it is `[models] enabled` on the node the clocks already run on. The bucket is the real item: **the bucket
Soma signs an upload for and the bucket every node reads from must be the same bucket**, and it has
**two addresses** — `MODELS_PUBLIC_ENDPOINT` is what a competitor's presigned PUT is signed for and
`MODELS_ENDPOINT` is what a node dials. SigV4 signs the host, so one variable for both is a URL only
one side can use, and the failure names neither: an SSRF refusal at the `head` stage about an
internal IP. It is worth stating plainly because the other failure mode is quiet — the upload
succeeds against a bucket no node reads, admission answers `ARTIFACT_MISSING`, and both halves look
healthy.

---

## 14. Decisions taken here

Decisions **20** (the admission timeout), **35** (the competitor declares both hashes), **36**
(admission is a clock inside Jodi — which is to say, since 16 September 2026, inside Soma), **37**
(no run fence — the per-row claim is the mutual exclusion), **38** (the game's budgets live in `games.manifest`), **39** (re-validation as the tail
of the run) and **40** (the stale-admission lockout replaced by a visible trial wait) were taken
here. Each is recorded with its reasoning in
[devops/docs/decisions.md](https://github.com/Tiny-Brains/devops/blob/main/docs/decisions.md) §3,
under *Admission*.

---

## 15. What the schema gains

The schema is pre-release, so these are edits to `soma/migrations/0001_init.sql` rather than an
`0003`, and [scripts/verify/](../scripts/verify/) re-runs against the result.

**`models` gains three columns**, all about the claim:

```sql
    admit_started_at timestamptz,          -- when the current attempt claimed it; NULL when free
    admit_token      uuid,                 -- which run holds it; the verdict statement checks it
    admit_attempts   int NOT NULL DEFAULT 0,
```

and one index, the mirror of the match claim's:

```sql
-- the admission claim: testing rows, oldest first
CREATE INDEX models_admit_claim_idx
    ON models (created_at) WHERE status = 'testing';
```

**`games` gains two**, §8's:

```sql
    manifest               jsonb,          -- the cartridge's declaration, verbatim
    reference_observations jsonb,          -- the admission fixture; worst case included
```

**Nothing is dropped and no constraint changes.** `models_past_testing_has_contents` is what makes
§5.5's verdict statement safe, and `models_adapter_matches_hash` is what makes §13's first ask
load-bearing; both were written for this and neither needs touching.

---

## 16. Open questions

1. ~~**Does `admit_token` want to be the occurrence id or a fresh uuid?**~~ **Settled by building
   it: a fresh uuid**, `{"random": ["uuid"]}` in the `token` task, the way pair mints its
   `pairing_id`. It needs only to be unique per run, and a fresh one depends on nothing Orion
   exposes to a cron workflow.
2. **`revalidate_batch` at the tail of every run, or only when the digest actually moved?** As
   written the query runs every 20 s and usually returns nothing, which is an index scan on a small
   table and probably fine — but "probably fine" is what a `[vars]` zero is for until it is measured.
3. **Should a `rejected` version be re-submittable at the same tag?** `models_owner_game_release_uniq`
   says no: the row exists, so the competitor must cut a new release. That is probably right — a
   rejection names bytes, and different bytes deserve a different tag — but it is a decision made by
   an index rather than by an argument, and it will be the first thing a competitor complains about.
4. **What does a baseline's admission look like?** A baseline is meant to be an ordinary submission
   by a `baseline`-role user, admitted through this exact path — which is what finally deletes
   `devops/scripts/dev/seed-baselines.sh`. Half of the old obstacle is gone: the baselines are real
   trained artifacts in `ants-baselines` now rather than untrained loader fixtures, so they have a
   repository that could cut releases. What is left is that the seeder writes the rows and uploads
   the objects directly, and admission would have to be driven by a real `POST /v1/submissions` with
   a real upload. That is a chore, not a design.
5. **Is the op allowlist per game or per platform?** the platform design says ~40 ops platform-wide,
   which is what §11 assumes. A cartridge whose observations are naturally recurrent might want
   `LSTM`; the manifest is where that would go, and this draft does not open it.
