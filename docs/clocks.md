# Design — the clocks

> **These pages were `jodi/docs/` until 16 September 2026**, when the clocks and their repository
> merged into Soma. A decision, a dated entry or a quoted log that says *Jodi* means these clocks.

The clocks are four cron channels in Soma's package over one database, and no application code. This page covers **count**,
**pair** and **withdraw**: what each run does, statement by statement, and why each is correct
without its singleton lock. The fourth clock is [`admission.md`](admission.md); what count does with
a result once it has folded it is [`rating-and-seasons.md`](rating-and-seasons.md); every number
cited below is [`config.md`](config.md).

The schema these statements run against is
[schema.md](schema.md). Who writes what,
and why the fences rather than the locks carry correctness, is
[devops/docs/architecture.md](https://github.com/Tiny-Brains/devops/blob/main/docs/architecture.md)
§3 and §5.

## 1. What this page fixes

| Settled here | Left to |
|---|---|
| the three channels: schedule, singleton key, timeout, tracing, misfire | 07 cluster mode, which makes the keys cluster-wide |
| which fence each clock claims, and why pair claims none of its own | — |
| count's run: the fence claim, the batch, the fold per match in finish order, the verdicts in the same run | 06 the TrueSkill parameters as final numbers |
| the verdict rules, the re-pair cap, and the reject reasons a competitor reads | 08 what the Version screen says while a trial waits |
| promotion's seed numbers, provisional | 06 the inflation and the prior as final numbers |
| the in-flight policy — decision 1 — and the demand view that counts it | 07 the autoscaler that reads the same view |
| pair's run: the roster read, the demand read, the room, the plugin call, the inserts, the trial insert | — |
| the pairing plugin's contract: what it is given, what it returns, what it must and must not do | the plugin's code, the build |
| the rating plugin's contract, in the fold's document shape | 06 tie semantics as a final rule |
| withdraw's schedule and its reason words | 07 where an alert goes |
| the numbers, in one `[vars]` block | a `policies` table, when a number must change without a deploy |

---

## 2. Orion facts the runs are shaped by

Verified against the 1.7.0 reference (`channel-config.md` cron transport, `workflows.md` loop,
`plugins.md` manifest) and the source cited in the schema §2.

1. **A cron channel** declares `transport_config.schedule` as a six-field cron expression —
   second, minute, hour, day, month, weekday — with `timezone`, `misfire_policy` (`skip`,
   `latest`, `catch_up`) and `concurrency: { "policy": "forbid", "key": "…" }`. The key is a
   literal lock name, cluster-wide; two channels naming one key serialise with each other. The
   channel's `config.timeout_ms` bounds a run. Unknown keys are refused at load.
2. **`tracing`** is per channel: `{ "mode": "async", "errors_only": true, "task_details": true }`.
3. **A workflow runs its whole task list once per sweep** when it declares `loop: { "counter":
   "i", "max": N }`; the counter lives in `temp_data`, and `temp_data` and `data` survive across
   sweeps. That is how one workflow processes each element of an array with a connector call per
   element, which JSONLogic `map` cannot do. A task meant for the first sweep only carries
   `"condition": { "==": [{ "var": "temp_data.i" }, 0] }`.
4. **Stopping early is a `filter` task with `"on_reject": "halt"`**, which ends the whole run, not
   the sweep. It is also how a run halts on a lost fence: the filter's condition reads the
   previous task's `rows_affected`.
5. **A plugin's functions are called by name like any built-in**, and the name is
   `<plugin id>.<label>` — `tb.rating.trueskill`, `tb.pairing.pair`. The guest receives the
   evaluated `input` object and returns one JSON value written at `output`. An input field can be
   `template_at`, so a task may hand the guest a JSONLogic result rather than a literal. A guest
   error with a `code` is a `caller_input` failure: recorded, never retried.
6. **`metadata.vars`** carries the instance's `[vars]` block, stamped on every run; a number below
   reaches a statement as `{ "var": "metadata.vars.<name>" }` in `params`, and `clippy -c` makes a
   missing one loud.
7. **`metadata.trigger`** is as the schema §2 lists it; `scheduled_for` and `attempt` are the fence,
   and `occurrence_id` is the pairing plugin's seed.

---

## 3. The channels

| Channel | Workflow | Schedule | Key | `timeout_ms` | `misfire_policy` | Tracing |
|---|---|---|---|---|---|---|
| `tb-count` | `tb-count-run` | `*/10 * * * * *` — every ten seconds | `count` | 60 000 | `latest` | `errors_only`, `task_details` |
| `tb-pair` | `tb-pair-run` | `*/15 * * * * *` — every fifteen seconds | `pair` | 60 000 | `latest` | `errors_only`, `task_details` |
| `tb-withdraw` | `tb-withdraw-run` | `0 * * * * *` — every minute | `withdraw` | 30 000 | `latest` | `errors_only`, `task_details` |

These three, plus `tb-admit` ([`admission.md`](admission.md)), are the four channels the package
ships. They are separate channels because their natural rates differ: count as often as results
arrive, pair as often as the queue drains, withdraw as the backstop, admit as submissions land. Each is a `forbid` singleton
on its own key, so two runs of one clock never overlap while the shared database is reachable —
and each is correct when they do (architecture §5.3), because:

- **count claims a run fence** — `clocks` row `count` — at its first task with its occurrence's
  `(scheduled_for, attempt)`, and every ladder write in the run checks it `FOR SHARE` (the schema §5.1,
  §5.2, §5.3). A stale run writes nothing and halts.
- **pair claims no run fence.** Every insert checks the **roster** epoch it read at run start
  (the schema §6.2), which is what "never pairs what has left" needs. A stale pair run — an old occurrence
  retried after a newer one — can insert up to the room it read, an overfill of at most one run's
  worth that the depth target bounds and the next run absorbs. That is not worth a second
  predicate on every insert; the `pair` row in `clocks` stays seeded in case it ever is.
- **withdraw claims nothing.** Its one statement is idempotent (the schema §7.1).

`timeout_ms` on count is short on purpose (finding 1): a node that dies holds the singleton for
the timeout plus a heartbeat, and count's batch is sized to finish well inside it (§9). `latest`
on all three: a tick missed while nothing ran is not replayed, because every run scans the same
state.

---

## 4. Decision 1 — the in-flight policy, and the demand view

**Decided 7 September 2026: a policy by state.** How many of a version's matches may be in
flight — `pending`, `claimed` or `running`, since a queued row was paired on an old prior too —
depends on what the ladder still has to learn about it.

| State | Who | Cap on its own matches | Why |
|---|---|---|---|
| **trial** | `verified`, no live trial row | 1 | `matches_one_live_trial_uniq` already says so; the trial is a playability check |
| **placement** | `active`, fewer counted matches on its class ladder than the burst | the **burst**, spread across the game's presets | a new version's first matches are all paired on the same prior whichever order they run in, so running them at once costs no information and saves the wait |
| **unsettled** | `active`, sigma above the settled threshold on either ladder | the **steady cap**, small | each result moves the rating; a pairing benefits from the last one |
| **settled** | `active`, sigma at or below the threshold on both ladders | 0 of its own | it plays as the most useful opponent for someone else, uncapped; its own rating barely moves. This is what lets demand fall as the ladder settles, and with it the replica count (architecture §7) |

**A baseline has no row of its own** (decision 28, 11 September 2026). It is paced by the four
states above like any version — a new season plays its baselines' placement against each other —
its owner is held to the season's queue share like anyone's, and it must settle before a season
can close by settling. What sets it apart is its tag, and §6.4: every trial seats one.

Rating and seasons's dynamics factor re-opens a settled version's sigma over time, which returns it to
`unsettled` and gives it matches again; that is the whole of what v1's "cold fraction" wanted
(decision 10, §9).

**The demand view** is a query, not a table (finding 8a), and it is what both pair and deployment's
autoscaler read. Per version: its state, its cap, how many it has in flight, and what it wants.
Demand is the sum of wants. With parameters `$1` game, `$2` burst, `$3` steady cap, `$4` settled
sigma:

```sql
WITH v AS (
    SELECT md.id AS model_id, md.weight_class,
           max(r.sigma) AS sigma, min(r.matches_played) AS played
      FROM models md
      LEFT JOIN ratings r ON r.model_id = md.id
     WHERE md.game_id = ($1)::uuid AND md.status = 'active'
     GROUP BY md.id, md.weight_class
), f AS (
    SELECT s.model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running')
     GROUP BY s.model_id
), w AS (
    SELECT v.model_id, v.weight_class, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.played < ($2)::int         THEN 'placement'
                WHEN v.sigma  > ($4)::float8      THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.played < ($2)::int         THEN ($2)::int
                WHEN v.sigma  > ($4)::float8      THEN ($3)::int
                ELSE                                   0 END AS cap
      FROM v LEFT JOIN f ON f.model_id = v.model_id
)
SELECT model_id, weight_class, state, sigma, played, in_flight,
       greatest(cap - in_flight, 0) AS want
  FROM w
 ORDER BY want DESC, sigma DESC, model_id
```

`played` is the smaller of the two ladders' counts — the class ladder's, since every match feeds
`open` — and `sigma` the larger, so a version is placed until its class ladder has seen the burst
and settled only when both ladders have. The **room** pair may fill is the smaller of demand and
what the depth target leaves: `least(sum(want), target - depth)`, with depth the game's `pending`
count — the target stays a staleness cap, never the signal (finding 8b). The autoscaler's number
is `sum(want)` alone, which leads the queue rather than following it.

**Worked**: fifteen active versions, three of them baselines, two promoted this morning, burst 8,
steady 2, threshold 3.0. This morning demand is about 2×8 + 6×2 = 28 matches; by evening, with
the newcomers settled, it is a trial or two and whatever the dynamics factor has re-opened. That
fall is the point.

---

## 5. Count's run — `tb-count-run`

One workflow, one loop, one fence. A run folds every unmarked `finished` row it can reach in
finish order, then decides every trial that has reached a terminal state, and does both under
the fence it claimed at its first task, because the overview (§4, §5 step 2) says trials are
decided in the same run that counts. The batch is one document: the folds first, then the
verdicts, each element carrying its kind, and the loop walks it.

```json
{
  "workflow_id": "tb-count-run",
  "condition": true,
  "loop": { "counter": "i", "max": 400 },
  "tasks": [
    { "id": "fence", "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "db_write", "input": { "connector": "soma-db",
        "query": "<the schema §5.1>", "params": [{ "var": "metadata.trigger.scheduled_for" },
                                         { "var": "metadata.trigger.attempt" }],
        "output": "temp_data.fence" } } },
    { "id": "fenced", "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "filter", "input": {
        "condition": { ">": [{ "var": "temp_data.fence.rows_affected" }, 0] }, "on_reject": "halt" } } },
    { "id": "batch", "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "db_read", "input": { "connector": "soma-db",
        "query": "<§5.1: folds then verdicts, one JSON document>",
        "params": [{ "var": "metadata.vars.count_batch" }, { "var": "metadata.vars.forfeit_strikes" },
                   { "var": "metadata.vars.repair_cap" }],
        "output": "temp_data.rows" } } },
    { "id": "more", "function": { "name": "filter", "input": {
        "condition": { "<": [{ "var": "temp_data.i" }, { "var": "temp_data.rows.0.body.n" }] },
        "on_reject": "halt" } } },
    { "id": "item", "function": { "name": "map", "input": { "mappings": [
        { "path": "temp_data.it", "logic": { "val": ["temp_data", "rows", 0, "body", "items", { "val": ["temp_data", "i"] }] } } ] } } },

    { "id": "priors",  "condition": { "==": [{ "var": "temp_data.it.kind" }, "fold"] },
      "function": { "name": "db_read",  "input": { "connector": "soma-db", "query": "<the schema §5.2 priors>",
        "params": [{ "var": "temp_data.it.id" }], "output": "temp_data.match" } } },
    { "id": "rate",    "condition": { "==": [{ "var": "temp_data.it.kind" }, "fold"] },
      "function": { "name": "tb.rating.trueskill", "input": { "match": { "var": "temp_data.match.0.row" },
        "beta": { "var": "metadata.vars.ts_beta" }, "tau": { "var": "metadata.vars.ts_tau" },
        "draw_probability": { "var": "metadata.vars.ts_draw_probability" } },
        "output": "temp_data.post" } },
    { "id": "fold",    "condition": { "==": [{ "var": "temp_data.it.kind" }, "fold"] },
      "function": { "name": "db_write", "input": { "connector": "soma-db", "query": "<the schema §5.2 fold>",
        "params": [{ "var": "metadata.trigger.scheduled_for" }, { "var": "metadata.trigger.attempt" },
                   { "var": "temp_data.it.id" }, { "var": "temp_data.post" }],
        "output": "temp_data.folded" } } },
    { "id": "held",    "condition": { "==": [{ "var": "temp_data.it.kind" }, "fold"] },
      "function": { "name": "filter", "input": {
        "condition": { ">": [{ "var": "temp_data.folded.rows_affected" }, 0] }, "on_reject": "halt" } } },

    { "id": "pass",    "condition": { "==": [{ "var": "temp_data.it.decision" }, "pass"] },
      "function": { "name": "db_write", "input": { "connector": "soma-db", "query": "<the schema §5.3 pass>",
        "params": [{ "var": "metadata.trigger.scheduled_for" }, { "var": "metadata.trigger.attempt" },
                   { "var": "temp_data.it.trial_id" }, { "var": "temp_data.it.model_id" },
                   { "var": "metadata.vars.prior_mu" }, { "var": "metadata.vars.prior_sigma" },
                   { "var": "metadata.vars.sigma_inflation" }],
        "output": "temp_data.promoted" } } },
    { "id": "withdraw", "condition": { "==": [{ "var": "temp_data.it.decision" }, "pass"] },
      "function": { "name": "db_write", "input": { "connector": "soma-db", "query": "<the schema §5.4>",
        "params": [{ "var": "temp_data.it.predecessor_id" }, { "var": "temp_data.it.model_id" }] } } },
    { "id": "reject",  "condition": { "==": [{ "var": "temp_data.it.decision" }, "reject"] },
      "function": { "name": "db_write", "input": { "connector": "soma-db", "query": "<the schema §5.3 reject>",
        "params": [{ "var": "metadata.trigger.scheduled_for" }, { "var": "metadata.trigger.attempt" },
                   { "var": "temp_data.it.trial_id" }, { "var": "temp_data.it.model_id" },
                   { "var": "temp_data.it.reason" }] } } }
  ]
}
```

Sweep 0 claims the fence, halts if it lost, and reads the batch; every sweep picks item `i`, halts
when the items run out, and runs the tasks whose condition matches the item's kind. A fold that
affects zero rows halts the run: the fence is gone or the row was already marked, and the next
occurrence starts clean. A pass that affects zero rows is not a halt — the candidate was decided
by a concurrent run — and the withdraw after it is idempotent. `max` is a literal bound above
`count_batch` plus any plausible number of verdicts; the filter is what ends the loop.

**Each decision is followed by its notification** (not drawn above): `notify_result` and
`notify_rank` after `held`, `notify_promoted` after `withdraw`, `notify_rejected` after `reject`.
Each is a separate `db_write`, `continue_on_error`, keyed so a replayed sweep inserts once, and each
reads the decision off the row — `rated`, `active`, `rejected` — rather than off `temp_data`. None is
inside a fenced statement: a notification that fails costs itself, never a fold or a verdict, and
the price is that a run which dies between the two loses that one notification.
[`schema.md`](schema.md) §3.11.

### 5.1 The batch — folds, then verdicts, as one document

```sql
WITH folds AS (
    SELECT json_build_object('kind', 'fold', 'id', m.id) AS item, 0 AS grp, m.played_at AS ord, m.id
      FROM matches m
     WHERE m.status = 'finished' AND m.trial_model_id IS NULL
     ORDER BY m.played_at, m.id
     LIMIT ($1)::int
), verdicts AS (
    SELECT json_build_object(
             'kind', 'verdict', 'model_id', c.id, 'trial_id', t.id,
             'predecessor_id', (SELECT p.id FROM models p
                                 WHERE p.owner_id = c.owner_id AND p.game_id = c.game_id
                                   AND p.status = 'active'),
             'trials', n.trials,
             'decision', CASE WHEN t.status = 'finished' AND cs.strikes < ($2)::int THEN 'pass'
                              WHEN t.status = 'finished'                          THEN 'reject'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat  THEN 'reject'
                              WHEN n.trials >= ($3)::int                           THEN 'reject'
                              ELSE 'repair' END,
             'reason',   CASE WHEN t.status = 'finished' AND cs.strikes < ($2)::int THEN NULL
                              WHEN t.status = 'finished'                          THEN 'FORFEIT'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat  THEN 'FAULT:' || t.fault_reason
                              WHEN n.trials >= ($3)::int                           THEN 'UNPLAYABLE'
                              ELSE NULL END) AS item,
           1 AS grp, t.played_at AS ord, c.id
      FROM models c
      JOIN LATERAL (SELECT t.* FROM matches t
                     WHERE t.trial_model_id = c.id
                       AND t.status IN ('finished', 'failed', 'cancelled')
                     ORDER BY t.created_at DESC LIMIT 1) t ON true
      JOIN match_seats cs ON cs.match_id = t.id AND cs.model_id = c.id
      JOIN LATERAL (SELECT count(*) AS trials FROM matches x WHERE x.trial_model_id = c.id) n ON true
     WHERE c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_model_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running'))
)
SELECT json_build_object('n', count(*),
         'items', coalesce(json_agg(item ORDER BY grp, ord, id), '[]'::json)) AS body
  FROM (SELECT * FROM folds UNION ALL SELECT * FROM verdicts) x
```

`$1` the batch size · `$2` the forfeit strike count · `$3` the re-pair cap. Folds come first, in
finish order, so a trial decided in this run is decided after every result that arrived before
it was counted. A `repair` item runs no task: the candidate is `verified` with no live trial and
fewer trials than the cap, which is exactly what pair's trial insert looks for (§6.4), so the next
pair run pairs it again, on the next preset. The decision is computed in SQL so the workflow only
dispatches; the rules are finding 6b's, as the table in §5.2 states them.

### 5.2 The verdict rules — finding 6b, with the words a competitor reads

| The last trial row | The candidate's seat | Decision | `reject_reason` |
|---|---|---|---|
| `finished` | strikes below the forfeit count | **pass** — promote (the schema §5.3), then withdraw the predecessor's queue (the schema §5.4) | — |
| `finished` | forfeited: strikes at the count | **reject** | `FORFEIT` |
| `failed` | `fault_seat` is its seat | **reject** | `FAULT:<fault_reason>` — `HASH_MISMATCH`, `GRAPH_INVALID`, `ADAPTER_INVALID`, or what Kalam adds |
| `failed`, unattributed — `LEASE_LAPSED`, `UNLOADABLE`, an engine trap; or `cancelled` — its baseline superseded, or the engine retired | — | **re-pair**: nothing written; pair inserts a fresh trial on the next preset | — |
| any of the above, once the candidate has had the cap's worth of trials with no pass | — | **reject** | `UNPLAYABLE` |

A pass does not look at the rank: the trial is a playability check, and a candidate that lost
cleanly is promoted (architecture §5 step 2). `UNPLAYABLE` is the one verdict an operator should hear
about, since it means the platform failed the same candidate repeatedly; where that alert goes is
deployment's, and until then the reject reason on the row is the record.

### 5.3 Promotion's numbers

The pass statement (the schema §5.3) takes the prior and the inflation as parameters. Provisionally, from
§9: `prior_mu = 25`, `prior_sigma = 25/3`, `sigma_inflation = 2`, the inflated sigma capped at
the prior. A class change seeds the class ladder from the prior. Rating and seasons finalises all three
(decision 11) and may replace the seed with the lazy variant; the statement's shape does not
change.

### 5.4 Whether count refuses foreign engine digests — decision 13

**No**, as the review left it (finding 5 option B deferred). A `finished` row whose
`engine_digest_played` is not the game's current digest is counted like any other: old replicas
drain their own rows across a deploy, and the ladder records what was played. If a rules change
ever makes two engines incomparable, that is a season boundary (rating and seasons), not a count rule.

---

## 6. Pair's run — `tb-pair-run`

One workflow, one loop. Sweep 0 reads the roster epoch, the demand, the depth and the trial
candidates, calls the pairing plugin for the room, and appends the trial pairings; every sweep
inserts one pairing with the schema §6.2 and halts when the pairings run out or an insert is fenced out.

```json
{
  "workflow_id": "tb-pair-run",
  "condition": true,
  "loop": { "counter": "i", "max": 200 },
  "tasks": [
    { "id": "epoch",  "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "db_read", "input": { "connector": "soma-db", "query": "<the schema §6.1>",
        "output": "temp_data.roster" } } },
    { "id": "demand", "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "db_read", "input": { "connector": "soma-db",
        "query": "<§6.1: the demand view, the pool, the presets played, the room, as one document>",
        "params": [{ "var": "metadata.vars.game_id" }, { "var": "metadata.vars.burst" },
                   { "var": "metadata.vars.steady_cap" }, { "var": "metadata.vars.settled_sigma" },
                   { "var": "metadata.vars.pair_depth_target" }],
        "output": "temp_data.demand" } } },
    { "id": "trials", "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "db_read", "input": { "connector": "soma-db", "query": "<§6.4>",
        "params": [{ "var": "metadata.vars.game_id" }, { "var": "metadata.vars.repair_cap" },
                   { "var": "metadata.vars.presets" }],
        "output": "temp_data.trials" } } },
    { "id": "pair",   "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "tb.pairing.pair", "input": {
        "demand": { "var": "temp_data.demand.0.body" },
        "presets": { "var": "metadata.vars.presets" },
        "cross_class_fraction": { "var": "metadata.vars.cross_class_fraction" },
        "seed": { "var": "metadata.trigger.occurrence_id" } },
        "output": "temp_data.paired" } },
    { "id": "plan",   "condition": { "==": [{ "var": "temp_data.i" }, 0] },
      "function": { "name": "map", "input": { "mappings": [
        { "path": "temp_data.plan", "logic": { "merge": [
            { "var": "temp_data.trials.0.body.pairings" }, { "var": "temp_data.paired.pairings" }] } },
        { "path": "temp_data.n", "logic": { "+": [
            { "var": "temp_data.trials.0.body.n" }, { "var": "temp_data.paired.n" }] } } ] } } },
    { "id": "more",   "function": { "name": "filter", "input": {
        "condition": { "<": [{ "var": "temp_data.i" }, { "var": "temp_data.n" }] }, "on_reject": "halt" } } },
    { "id": "item",   "function": { "name": "map", "input": { "mappings": [
        { "path": "temp_data.it", "logic": { "val": ["temp_data", "plan", { "val": ["temp_data", "i"] }] } },
        { "path": "temp_data.pairing_id", "logic": { "random": ["uuid"] } } ] } } },
    { "id": "insert", "function": { "name": "db_write", "input": { "connector": "soma-db",
        "query": "<the schema §6.2>",
        "params": [{ "var": "temp_data.roster.0.epoch" }, { "var": "metadata.vars.game" },
                   { "var": "temp_data.it.seed" }, { "var": "temp_data.it.preset" },
                   { "var": "temp_data.it.seats" }, { "var": "temp_data.it.trial" },
                   { "var": "temp_data.pairing_id" }],
        "output": "temp_data.inserted" } } },
    { "id": "held",   "function": { "name": "filter", "input": {
        "condition": { ">": [{ "var": "temp_data.inserted.rows_affected" }, 0] }, "on_reject": "halt" } } }
  ]
}
```

Trial pairings come first in the plan so a waiting candidate is never crowded out by the room.
An insert that affects zero rows halts the run: the roster moved, and the next run re-reads.

### 6.1 The demand read — the view, the pool, the presets played, the room

One document: `wants`, the §4 view; `pool`, every `active` version, baselines included, with its two
ratings, class and in-flight count, which is who the plugin may seat opposite a want; `played`,
per version per preset, how many counted matches, for map coverage; and `room`. The view is §4
verbatim as a CTE; the rest:

```sql
, pool AS (
    SELECT md.id AS model_id, md.weight_class,
           (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                            ORDER BY r.ladder) FROM ratings r WHERE r.model_id = md.id) AS ratings
      FROM models md
     WHERE md.game_id = ($1)::uuid AND md.status = 'active'
), played AS (
    SELECT s.model_id, m.preset, count(*) AS n
      FROM match_seats s JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated')
     GROUP BY s.model_id, m.preset
), depth AS (
    SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending'
)
SELECT json_build_object(
         'demand', (SELECT coalesce(sum(want), 0) FROM w),
         'depth',  (SELECT pending FROM depth),
         'room',   greatest(least((SELECT coalesce(sum(want), 0) FROM w),
                                  ($5)::int - (SELECT pending FROM depth)), 0),
         'wants',  (SELECT json_agg(w ORDER BY want DESC, sigma DESC) FROM w WHERE want > 0),
         'pool',   (SELECT json_agg(pool) FROM pool),
         'played', (SELECT json_agg(played) FROM played)) AS body
```

`$5` is the depth target. Everything the plugin needs to choose is in this one read, taken at one
instant, so a run's pairings are consistent with each other; the roster fence guards the instant
against a promotion.

### 6.2 The pairing plugin — `tb.pairing.pair`

**Input**: the §6.1 document, the game's presets, the cross-class fraction, and a seed — the
occurrence id, so a retry of the same occurrence proposes the same pairings and an audit can
replay the choice. **Output**: `{ "n": k, "pairings": [{ "seats": [a, b], "preset": "…", "seed":
s }, …] }` with `k ≤ room`, the seats' ids in seat order, and a world seed per pairing derived from
the run's seed and the index.

**What it must do**, in this order, for each want from largest to smallest until the room is used:

1. **The preset** is the one the wanting version has played least, ties broken by the seed —
   map coverage, so a rating reflects the game rather than one map (architecture §7).
2. **The opponent** is drawn from the pool, never the version itself, never one with a live trial
   against it. With probability equal to the cross-class fraction it comes from another class,
   so `open` is one graph rather than a union of class ladders (schema §3, the platform design §12.7);
   otherwise from the same class. Within the chosen set, prefer another version that also
   wants a match — one row then serves two wants — and among those the closest `mu` on the
   ladder they share, weighted toward larger sigma, which is where a result teaches the most. A
   settled version is the fallback, and for a placement burst it is the usual partner, since a
   newcomer's own prior says nothing about who is close.
3. **Decrement** both seats' wants when both wanted; a seat over its cap is never chosen as the
   wanting side, but a settled version or a version with want zero may be seated opposite,
   limited only by its owner's queue share.
4. **Stop** at the room. If wants remain, the next run continues from a fresh read.

**What it must not do**: read or write anything — it is pure, seeded, and its output is the
whole of its effect; seat a `verified`, `superseded` or `rejected` version, which the pool never
contains; pair a trial, which §6.4 does without it; or emit a pairing whose seats share a
version.

A first implementation may pick opponents uniformly within the class rule and still be correct;
the ordering rules above are what pairing quality asks for, and the cross-class fraction is
decision 9 ([`config.md`](config.md)).

### 6.3 The insert

the schema §6.2, once per pairing, with the epoch read at sweep 0. The statement derives hashes, ladders,
the contesting check and the rating snapshot itself; the plugin's output is ids, a preset and a
seed. `rows_affected` of 2 is a match; 0 halts the run.

### 6.4 The trial insert — SQL, no plugin

A `verified` version with no live trial row and fewer trials than the cap gets one, against a
baseline of its own class if one exists, else any baseline, preferring the baseline with the
fewest matches in flight; on the preset after the one its last trial used, so a re-pair changes
the map. As a document in the plan's shape:

```sql
SELECT json_build_object('n', count(*), 'pairings', coalesce(json_agg(json_build_object(
         'seats', json_build_array(c.id, b.id), 'trial', c.id,
         'preset', (($3)::text[])[1 + (n.trials % cardinality(($3)::text[]))],
         'seed', (random() * 2147483647)::bigint)), '[]'::json)) AS body
  FROM models c
  JOIN LATERAL (
        SELECT b.id
          FROM models b
          JOIN users ub ON ub.id = b.owner_id AND ub.role = 'baseline'
         WHERE b.game_id = c.game_id AND b.status = 'active'
         ORDER BY (b.weight_class = c.weight_class) DESC,
                  (SELECT count(*) FROM match_seats s JOIN matches m ON m.id = s.match_id
                    WHERE s.model_id = b.id AND m.status IN ('pending', 'claimed', 'running')),
                  b.id
         LIMIT 1) b ON true
  JOIN LATERAL (SELECT count(*) AS trials FROM matches x WHERE x.trial_model_id = c.id) n ON true
 WHERE c.game_id = ($1)::uuid AND c.status = 'verified'
   AND n.trials < ($2)::int
   AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_model_id = c.id
                      AND l.status IN ('pending', 'claimed', 'running'))
```

`$1` game · `$2` the re-pair cap · `$3` the presets. The trial's seed is random rather than
derived, since nothing replays a trial's choice. A candidate at the cap is left to count, which
rejects it as `UNPLAYABLE` (§5.2).

---

## 7. Withdraw's run — `tb-withdraw-run`

One task: the schema §7.1, every minute. No fence, no loop, no plugin; `rows_affected` is a metric of how
often the backstop caught something, which under normal operation should be the odd row that
lapsed back to `pending` after promotion's own withdraw ran.

The run is four tasks now: the sweep, the game, the season close ([rating-and-seasons.md](rating-and-seasons.md)
§5.2), and `notify_closed`, which runs only when the close wrote and tells everyone who entered the
season that it closed and where they finished on open ([`schema.md`](schema.md) §3.11).

**The reason words**, as the sweep and promotion write them and Soma shows them (finding 12.4):

| `withdrawn_reason` | Written by | What the competitor reads |
|---|---|---|
| `SUPERSEDED` | promotion's second statement, or the sweep | "withdrawn: your v3 replaced v2 before this match was played" — with `successor_id` |
| `REJECTED` | the sweep | "withdrawn: the version was rejected" — only reachable for a trial's rows when a candidate is rejected at the cap with a row still queued |
| `SEAT_LEFT` | the sweep | "withdrawn: an opponent left the ladder" — `retired` in the build, or any status added later, since contesting is stated by inclusion |
| `ENGINE_RETIRED` | the sweep | "withdrawn: the game engine was updated before this match was played" |

A `cancelled` row is not a fault: no lapse, no strike, no rating change, and it never re-points
at the successor, who is paired afresh (decision 12 in the overview's log).

---

## 8. The rating plugin — `tb.rating.trueskill`

**Input**: the [schema.md](schema.md) §5.2 priors document — `ladders`, `seat_count`, and per seat its `seat`,
`model_id`, `rank`, `strikes` and `ratings` per ladder — plus `beta`, `tau` and
`draw_probability`. **Output**: the fold's `$4` exactly — one element per seat per ladder,
`{ "seat", "model_id", "ladder", "mu", "sigma" }` — so the task passes it straight to the
statement, which records what it replaced and refuses the document if its length is wrong.

**Rules.** One TrueSkill update per ladder the match feeds, over the seats' priors on that ladder,
ordered by `rank`. **Ties** (decision 12): equal ranks are a draw. Whether the engine numbers ties
densely (`1, 1, 3`) or competition-style (`1, 1, 2`) does not reach the update, which reads only
the order of ranks and which are equal — so the rule is "equal means drew", and the numbering is
the engine's business; rating and seasons restates it as final. The dynamics factor `tau` is applied per
update as TrueSkill defines it, which is what re-opens a settled sigma over time (§4); rating and seasons
sets its value. `strikes` are input only: a forfeited seat already ranks last (the schema §4.6).

**Errors**, all `caller_input`, never retried: `RANKS_LENGTH_MISMATCH`, `LADDER_MISSING` — a seat
with no rating on a ladder the match feeds — `SIGMA_NOT_POSITIVE`, `SEATS_BELOW_TWO`.

**Provisional parameters** (§9): `beta = prior_sigma / 2`, `tau = prior_sigma / 100`,
`draw_probability = 0.10`, the library defaults scaled to the prior; Ants can draw.

---

## 9. The numbers

Every number the runs read — the batch sizes, the depth target, the burst and steady caps,
the settled threshold, the priors and the TrueSkill parameters — is in [`config.md`](config.md),
with what moves each and, where the running ladder can measure it, the query that does.

## 10. What is verified, and what is not

**Verified on Postgres 16**, in the same harness as the schema (`01-verify/run.sh`, statements
`d_demand`, `c_decide`, `p_trials`): the demand view returns a state, cap and want per version
and the room; the verdict read returns `pass` for a finished trial whose candidate did not
forfeit and `reject` with `FAULT:HASH_MISMATCH` for one failed on the candidate's seat; the trial
read pairs a waiting candidate with a same-class baseline on the next preset and skips one with a
live trial.

**Not verified** — the build's and the build's: the loop, the conditioned first-sweep tasks and the `filter`
halt on a real Orion run; that a halted run is not recorded as an error; the two plugins, whose
contracts are here and whose code is the build's; count's run length against its timeout at the batch
size; and every number in §9, which only a running ladder tunes.

---

## 11. Decisions taken here

Decisions **1** (matches in flight per version), **7** to **13**, and the unnumbered calls the runs
forced — verdicts folded in the same run, pair claiming no run fence, the trial insert as SQL —
are recorded with their reasoning in
[devops/docs/decisions.md](https://github.com/Tiny-Brains/devops/blob/main/docs/decisions.md) §3,
under *The clocks*.
