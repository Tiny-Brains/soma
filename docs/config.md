# Configuration

> **These pages were `jodi/docs/` until 16 September 2026**, when the clocks and their repository
> merged into Soma. A decision, a dated entry or a quoted log that says *Jodi* means these clocks.

Every number the clocks read, what it means, what moves it, and — where the running ladder can
measure it — the query that does. They live in the `[vars]` block of the instance config that runs
Soma, `docker/soma.toml.tmpl`, sectioned `CLOCKS`, read by the runs as
`metadata.vars.*`.

**Every one of these is provisional.** A number here is a policy guess unless the *Measured by*
column names something that has actually been run against it.

> **`metadata.vars` is ROOT scope.** A `[vars]` value read inside a `map` or `filter` body is
> `null`, and `{">=": [0, null]}` is *true* — so a ceiling read in the wrong scope silently passes
> every test against it. Every accumulator is a `reduce` with the value carried in its seat, and the
> first task of each run halts loudly if a var is missing. This cost a day; see
> [orion-notes.md](orion-notes.md) §4.

The day a number must change without a redeploy, these move to a `policies` table — versioned,
immutable, and read in the run that acts on it. Nothing depends on that yet.

---

## 1. The game

| Var | Value | What moves it |
|---|---|---|
| `game` | `ants` | a second game makes this a roster rather than a name |
| `engine_digest` | the image's own cartridge, exported by the entrypoint | the engine this node loads, which a map upload compares with the season's: validating a board on another engine proves nothing (N28). **There is no board list here any more**: a season's boards are `season_maps`, uploaded and enabled by an admin, and pair picks only one the roster can seat — the plugin filters by distinct owners in the pool, the trial query by the season's baselines — so a wide board waits for a roster that can fill it. A replica claims up to eight seats (kalam `MAX_SEATS`), the top of `limits.boards` |

## 2. The clocks

| Var | Value | Decision | Why this value, and what moves it |
|---|---|---|---|
| `count_batch` | 50 | 7 | three tasks a match, well inside a 60 s timeout at ten a second. Raise it if count lags the match rate |
| `pair_depth_target` | 64 | 7 | about two waves for four replicas: deep enough that a claim never waits, shallow enough that a pairing is at most a few minutes old. **The autoscaler must never read queue depth**, because this caps it — see decision 43 |
| `burst` | 8 | 1 | a handful of boards and a few more; enough for TrueSkill to leave the prior. All eight are paired on one prior, so more buys wall time, not information |
| `steady_cap` | 2 | 1 | one result lands while the next is paired. Raise it if replicas idle on a small roster |
| `repair_cap` | 3 | 8 | three platform failures in a row on one candidate is an incident, not a coincidence |
| `forfeit_strikes` | 5 | — | **must equal Kalam's `strike_ceiling`.** Kalam applies it; count reads its consequences off the row. A disagreement means count judges a trial by a rule the wave did not play by, silently. `devops/scripts/check/configs.sh` asserts the equality |

## 3. The rating

| Var | Value | Measured by | What the running ladder says |
|---|---|---|---|
| `prior_mu`, `prior_sigma` | 25, 8.3333 | nothing — it is a scale | TrueSkill's convention. **Soma reads these too**, for the baselines a season create carries, and the two must agree. Safe today only because both are in one config file; it stops being safe the day Soma gets a server of its own |
| `ts_beta` | 4.1667 (`prior_sigma / 2`) | the fraction of matches the lower-rated seat wins, binned by rating gap; `beta` is the gap at which the favourite wins ~76% | not measurable on a field that draws |
| `ts_tau` | 0.0833 (`prior_sigma / 100`) | the sigma floor: `min(sigma)` over settled versions | 0.70 — the floor is doing its job |
| `ts_draw_probability` | 0.10 | §5's query, per season | **99.8%.** See §5 — this is the number most obviously wrong, and it is wrong because of the field, not the code |
| `sigma_inflation` | 2.0, capped at the prior | how many placement matches a promoted version needs before its sigma is back where its predecessor's was | one promotion observed: 0.71 → 1.43, settled again within its burst |
| `settled_sigma` | 3.0 | how many counted matches a version has when it crosses the threshold | ~20 from the prior, as expected. **Also decides when a season closes** |

## 4. Admission

| Var | Value | What moves it |
|---|---|---|
| `admit_batch` | 4 | how many submissions a run may take; raise it when a queue forms |
| `admit_timeout_s` | 180 | the first real `Large` submission, where the object read and the graph build set the floor. **Untested at the top of the class range** — nothing that large has been submitted |
| `admit_attempts_max` | 3 | evidence that a transient class of failure is being counted as a real attempt |
| `admit_deadline_ms` | 5000 | the `tb-probe` call's timeout, covering every reference observation |
| `revalidate_batch` | 4 | the re-validation sweep's batch; **zero disables the sweep** |
| `opset_min` | 13 | the season's pin |
| `opset_max` | 19 | the season's pin |
| `op_allowlist` | ~40 names | a legitimate ONNX export that the list refuses |

**Not here, on purpose.** `adapter_ops_max` is the *game's* and comes from
`games.manifest`. The weight-class thresholds are the *season's* and come from
`seasons.weight_classes`, which the `classify` task reads directly — so a class boundary is
declared once, where the schema's CHECK can hold it, rather than in a config a deploy can edit.

## 5. What the running ladder measured

`ts_draw_probability` is the one number the live stack contradicts, and the finding is worth more
than the number.

**2,329 of 2,334 counted matches were draws — 99.8%** — nearly all ending `idle_food`. A draw
probability of 0.10 tells TrueSkill that each of those draws was a surprise.

The ratings are not wrong for it: five versions that always draw *are* equal, and the ladder says
so. What it shows is that **`ts_draw_probability` is a property of the field, not of the game.** The
field was five versions of untrained fixture weights, placed by hand — so they idled until the
food-idle rule ended the match. The number must be re-measured, by the query below, once trained
baselines and real submissions are on the ladder. **0.10 stays as the provisional value for a field
that plays.**

It is also the sharpest argument for the baselines becoming real submissions: *a trial against an
opponent that cannot lose proves only that the candidate can stand still.*

```sql
WITH r AS (
    SELECT m.id, count(DISTINCT st.rank) AS distinct_ranks
      FROM matches m JOIN match_seats st ON st.match_id = m.id
     WHERE m.status = 'rated' AND m.trial_model_id IS NULL AND m.season_id = ($1)::uuid
     GROUP BY m.id)
SELECT count(*) FILTER (WHERE distinct_ranks = 1)::float8 / nullif(count(*), 0) AS draw_fraction,
       count(*) AS counted
  FROM r
```

## 6. Numbers the clocks do not own but must agree with

| Value | Owned by | What a disagreement does |
|---|---|---|
| `forfeit_strikes` | pair, stamped on `matches.strike_ceiling` (decision 54) | none left: Kalam reads the row it claimed rather than a copy of its own |
| `prior_mu`, `prior_sigma` | the routes and the clocks, one `[vars]` block | none since the merge: there is one copy |
| `season_gap_days` (1) | Soma | a product decision, not a measurement |
| `adapter_ops_max` | the game's manifest | — |

web's `scripts/check/configs.sh` asserts the equalities that a deploy can get wrong, and runs
before either config ships. A rule that lives only in a comment is one rebase from being wrong, and
each of these fails silently.

---

## More

- [`clocks.md`](clocks.md) — what the clocks do, and why they are correct without their locks
- [`decisions.md`](decisions.md) — the reasoning behind each decision number cited above, and where the rest of the record is
