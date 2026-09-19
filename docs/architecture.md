# Architecture

> **Moved from `devops/docs/` on 17 September 2026**, when devops stopped running anything (N25), to the
> repository that owns the contract it is built around: the match table. It was written before N25, so
> where it names in-cluster Kalam replicas, the loader or an Orion image devops built, the platform now
> runs a Soma node image that loads its own package, runners from kalam's compose file, and web's
> `docker-compose.yml`.

The whole-system map. Every repository's `README.md` links this page and none repeats it; if a
statement about who talks to whom appears in two places, this is the one that is right.

The reader-facing half — what a competitor sees — is [the book](https://github.com/Tiny-Brains/web/tree/main/docs).
This page is for someone who will change the code, run it, or deploy it.

---

## 1. The parts

| Part | Role in one sentence | Host | Cardinality | State it owns |
|---|---|---|---|---|
| **[Soma](https://github.com/Tiny-Brains/soma)** | The public API for the web shell and the SDK: sign-in, submissions, models, matches, leaderboard — and **the runner gate**, the eight match statements behind `/v1/runner/*`, so a replica can play without a database credential. | Soma's Orion | N, cluster mode | none — reads and writes the database |
| **Soma's clocks** — the match maker (the `jodi` package until 16 September 2026) | Four clocks: **admit** registers a submission on its node, admits it, probes its adapter and writes one verdict; **withdraw** cancels the queued matches of versions that stopped contesting and of engines that retired; **pair** inserts up to the smaller of the ladder's demand and the room under a depth target, and gives a verified version its trial; **count** folds finished matches into ratings, decides trial rows, and promotes. Plus `tb-probe`, a channel rather than a clock. | part of Soma's package, in Soma's Orion | each clock a **cluster-wide singleton** on its own key, and correct with several running: every write is fenced | none |
| **[Kalam](https://github.com/Tiny-Brains/kalam)** — the game manager | Two clocks: **match** claims ONE `pending` row — over SQL in `db` mode, through Soma's gate in `api` mode — and plays it turn by turn, one `model_infer` per seat, finishing it with its result and replay key; **roster** keeps this node's model registry in step with `model_versions`. **Knows nothing about ratings or the roster's decisions** — it reads six columns and writes none. | Kalam's Orion — inside the deployment, or on a machine it does not own | N replicas x 4 match channels, scaled by the ladder's demand; drains on SIGTERM | none — a crash loses one match |
| **[Ants](https://github.com/Tiny-Brains/ants)** — the game engine | The rules of one game: world generation, observation, step, scoring, replay decoding. Pure, deterministic, and wave-shaped — one call advances every live match it is given, which is one match now. Also the **owner of the visibility mask**, which it sends rather than leaving every competitor to re-derive. | **a plugin inside Kalam** | one per game | none |
| **Manifest** | A competitor's declaration: the model's name, its inputs and outputs with their dtypes and shapes, and one JSONLogic **adapter** per input turning the game's observation into that input's tensor. The head is read by the platform, so it carries no `result`. | **data**, uploaded beside the model; evaluated by **datalogic** under an operation budget the game's manifest publishes | one per model version | none |
| **Orion's `models` entity** | What Axon was. A model row is a manifest plus an artifact reference — connector, key, `sha256:` digest — and the node fetches the object, re-hashes it, reads the graph, probes it, and afterwards serves `model_infer` from an LRU session cache under `tract`. | inside each Orion that needs it: admission on Soma's, play on each replica's | one registry per node | the artifact cache and the loaded sessions |
| **Postgres** | The system of record: the match table is **both the queue and the history**, plus ratings, models, seasons, the `clocks` table that carries the fences, and `runner_keys` and `runners`, which say who may play and who is. | managed | 1 | everything durable |
| **Object store** | Replay blobs by attempt, private; and the models bucket, **public-read** (N3): `models/<version_id>/model.onnx` and `manifest.json`, which the competitor uploads to through a presigned PUT and every node fetches by digest. | R2 | 1 | blobs |

Soma is one package: its REST endpoints, the runner gate, and four cron channels with their
workflows and plugins. Kalam is a **second package on a second Orion**, with its own connectors, its own instance config, its own
plugins and no shared Orion state with the first. **There is no third process**: inference is
Orion's, in whichever node needs it, which is what deleting Axon bought.

**Packaging is not deployment.** `soma/` and `kalam/` are two repositories, each shipping a
self-contained Orion package that knows nothing of the topology, and `devops/` decides how many
servers there are and which package goes in which. Until 16 September 2026 the clocks were a third,
`jodi/`, "so that the day Soma's REST surface must scale independently of the match maker, Jodi
gets its own service and neither repository changes" — but that day never came, the two always
loaded into one orion-server and one `[vars]` block, and the boundary cost a copy of every loader
and check script, one of which had stopped seeing most of its statements. **If the clocks ever do
need a server of their own, that is a second package compiled from one repository, not a second
repository.**

**The names.** *Jodi*, "a pair" in Hindi and in every southern language, named the clocks while they
were a repository of their own; the channel ids keep the platform's `tb-` prefix. *Kalam*
(களம்) is "the arena", the field a contest is fought on, in Tamil and Malayalam, and *kaḷa* in
Kannada. *Soma* is the body the whole thing hangs off; *ants* is the
first game.

A game defines only the **JSON shapes** its engine speaks — the observation a seat receives and the
action it answers. What a model consumes is the competitor's business, and the adapter is where
they spend that freedom.

---

## 2. Shape

```
      browser / SDK
            │
            ▼
 ┌────────────────────────────────────┐          ┌──────────────────────────────────────┐
 │  SOMA's ORION  (cluster, × N)      │          │  KALAM's ORION  (× N, db or api)     │
 │                                    │  HTTPS   │                                      │
 │  REST channels   the public API    │◀─────────┤  cron  tb-match × 4   claim ONE row  │
 │  RUNNER GATE  /v1/runner/*: the    │ api mode │  cron  tb-roster      keep this      │
 │     eight match statements, one    │          │        node's models in step         │
 │     route each; the reap, once     │          │  workflow  the turn loop: observe,   │
 │  cron  CLOCKS four clocks, each a  │          │            one model_infer per seat, │
 │  singleton, every write fenced:    │          │            step, finish              │
 │  admit · withdraw · pair · count   │          │  plugin  GAME ENGINE  (per game)     │
 │  plugins  rating math ·            │          │  MODELS   the roster, served by tract│
 │           pairing math             │          └────────┬──────────────────┬──────────┘
 │  MODELS   admission only: register,│                   │ db mode only:    │ fetch by
 │           admit, probe, archive    │                   │ claims, renews,  │ connector
 └──────┬─────────────────┬───────────┘                   │ finishes rows;   │ and digest
        │ HEAD + GET      │ inserts rows; folds,          │ reads six model  │
        │ the manifest;   │ decides, promotes,            │ columns          │
        │ fetch by digest │ withdraws; and the            │                  │
        ▼                 │ gate's eight, as              │                  │
                          │ runner_gate                   │                  │
                          ▼                               │                  │
                  ┌───────────────────────────────────┐   │                  │
                  │  POSTGRES                         │◀──┘                  │
                  │  matches (queue + history) ·      │                      │
                  │  model_versions · ratings ·       │                      │
                  │  models · seasons · clocks ·      │                      │
                  │  runner_keys · runners            │                      │
                  └───────────────────────────────────┘                      │
                                                                             │ + replay PUT,
                                                                             │ presigned
   competitor ──presigned PUT──▶ ┌───────────────────────────────────┐       │
                                 │  OBJECT STORE                     │◀──────┘
                                 │  replays (private) ·              │
                                 │  models bucket (public-read)      │◀── signed GET, via Soma
                                 └───────────────────────────────────┘
```

Lines are SQL unless labelled. Each Orion's `models` entity reaches the object store through its own
storage connector — admission to read a manifest and fetch an artifact, a replica to fetch the same
artifact by the same digest — and each node's clocks reach **their own** admin API over loopback,
never the other's. The competitor's two files arrive by a presigned PUT that Soma minted, which is
why nothing here fetches from the internet. **The two Orion instances never speak** — except that an
`api`-mode replica calls Soma's runner gate, whose routes run the statements a `db`-mode replica
runs itself. §3a is why that is not a second coupling.

---

## 3. The contract: one table, one row per match

Everything between the two Orion instances is one table. A row is born `pending` when Soma's pair clock
decides a match should happen, is played and finished in place by Kalam, and is counted in place by
Soma's count clock — or
withdrawn in place if a seat leaves the roster or its engine retires first, or failed in place when
it cannot be played. Its columns are
[`soma/docs/schema.md`](https://github.com/Tiny-Brains/soma/blob/main/docs/schema.md); what the row
*says*, and who may write each part, is fixed here.

| The row says | Written by | When | Read by |
|---|---|---|---|
| **what to play** — game, seats (which model version in which seat, with its hashes and its adapter reference), the board -- one of the season's enabled maps, sent whole on the claim (N28) --, seed, which ladders it counts for — none for a trial — and the engine digest it requires | Soma's pair clock | at insert | Kalam; Soma, to show "playing now" if it wants to |
| **why it exists** — a pairing id and the rating snapshot it was paired on | Soma's pair clock | at insert | audit |
| **who is playing it** — status, a claim token, a lease expiry, an attempt count, a refusal count, and the runner that holds it (`played_by`, through the gate) | Kalam, directly or through the gate, which then mints the token | at claim; on renew; the reap returns a lapsed lease | Kalam; the Runners screen |
| **what happened** — ranks, scores, reason, per-seat strikes, duration, the engine digest it played and the Orion version that ran it; on failure, a reason and the seat it is attributed to | Kalam | at finish, or at failure | Soma's routes and its count clock |
| **where the replay is** — the object key, named per attempt, of a JSON blob only the game's visualiser understands | Kalam | at finish | Soma, which signs a `GET` |
| **what it did to the ladder** — the mark that it has been counted, and per seat and per ladder the rating before and after; the mark alone for a trial | Soma's count clock, under its fence | at rating | Soma (the Version screen), audit |
| **why it will not be played** — withdrawn, and the version that replaced the seat or the engine that retired | Soma's count clock at promotion, or its withdraw clock | in the statement after the flip; on withdraw's schedule | Soma, to tell the competitor; audit |

The status walk, and who may make each move:

```
pending ──claim (1 row)───▶ claimed ──start──▶ running ──finish──▶ finished ──count──▶ rated
  ▲ ▲ │                        │                  │                   Kalam               Soma
  │ │ └─ a seat leaves the roster, or its engine retires ─▶ cancelled
  │ │                                     (count at promotion, or the withdraw clock)
  │ └─── lease lapses; the reap returns it  ◀──┴──────────┘
  └───── this node lacks a seat's model; a refusal spent    a third lapse, or a fault
                                                            Kalam can name ─────▶ failed
```

- `pending → claimed` is one `UPDATE … FOR UPDATE SKIP LOCKED … LIMIT 1` carrying a token.
  **That statement is the whole of coordination between N Kalam replicas**, whether a replica runs
  it or the gate runs it on the replica's behalf. It reads the status, the engine digest the row
  requires and the seat count, and orders trial rows first; through the gate it also refuses a
  runner that is no longer live or already holds its in-flight ceiling. It reads nothing else:
  Kalam never joins the roster.
- **A `pending` row is played only while its seats are contesting and its engine is current.** Every
  roster write goes through the **roster fence**, a counter in the `clocks` table. Promotion is two
  statements: the first bumps the fence and flips the versions, the second withdraws every `pending`
  row the predecessor was to play, naming the successor. Pair reads the fence at the start of a run
  and every insert checks it, read `FOR SHARE`, so a pair insert either committed before the flip and
  is seen by the withdraw, or fails after it and the run halts. The window between the two statements
  is the claim instant; a row claimed in it is played and counted, like any claimed row. Soma's
  withdraw clock sweeps every minute or so for what remains. `cancelled` is terminal and not a fault:
  no attempt spent, no strike, and the competitor sees it as withdrawn. A withdrawn row is never
  re-pointed at the successor; the successor is paired afresh. "Contesting" means `active`, or
  `verified` for the candidate seat of a trial row, stated by inclusion so a status added later fails
  closed.
- A lease that lapses is reaped — by `soma-runner-reap`, one cron channel on Soma's cluster-mode
  node, every second, and in `db` mode also by each replica's claim run — which returns the row to
  `pending` with its attempt count raised; the third lapse makes it `failed`. A replica that dies
  loses its match and nothing else; the rows are played again from turn 0 by whoever claims them
  next. A fault Kalam can name — a hash that does not match, a graph or an adapter the loader cannot
  build — fails the row at once, with the seat it is attributed to, and no one is charged an attempt
  for it. A replica whose own node has not yet registered a seat's model — the roster clock's lag —
  releases the row without an attempt, under a refusal count of its own.
- **Finish is one statement per row**, conditioned on the claim token: write the result and the
  replay key onto the row and set `finished`. A stale attempt — one whose lease lapsed and whose row
  was claimed again — holds a token the row no longer carries, so its finish updates nothing, and
  its replay blob, keyed by attempt, is an orphan rather than a replacement. A match that dies
  mid-run has written nothing. Kalam touches no other table, **and neither its database role nor the
  gate's can write another** — `runner_gate` adds only the runner's own `runners` row and a key's
  `last_used_at` (N17).
- **Counting is one statement per match**, made by Soma's count clock in finish order: mark the row
  `rated`, and in the same statement apply the posteriors to the rating rows, gated on the mark having
  landed and on the **count fence**. The mark makes a match count **at most once under any
  concurrency**; the fence makes a stale run write nothing at all. A run claims its fence — the
  occurrence's instant and attempt, monotonic per channel — at its first task; every write checks that
  the fence row still carries it, read `FOR SHARE` so the row lock rather than the snapshot orders the
  check; a run that finds its fence gone halts. A trial takes the same step with no posteriors, and is
  decided in the same run.
- The singleton lock on each clock therefore buys **efficiency and order, not correctness**. Order
  within a run is finish order; a second run cannot interleave, only lose.
- `finished` and `rated` rows are permanent and are what Soma lists. `failed` and `cancelled` rows
  are kept too, so a competitor can be told why a match never happened. Nothing is deleted;
  retention is a season question — see [`deployment.md`](deployment.md).

---

## 3a. Two ways to reach the queue

A replica reaches the match table one of two ways, set by `KALAM_MODE`, and **below the claim the
run does not know which**: both paths meet at the execution contract, and the turn loop, the refs,
the head decode and the replay envelope are the same tasks. `tinybrains conform` re-simulated
matches played each way as IDENTICAL, every field and every turn.

| | `db` | `api` |
|---|---|---|
| **Where it runs** | inside the deployment | anywhere with an outbound connection — no inbound port. An arm64 machine on a desk is the first |
| **What it holds** | `KALAM_DB_URL` on the `kalam` role, and the bucket's keys | a runner key, and a GET-only key on the public-read models bucket (N4). No connection string, no write key, no admin token |
| **How it claims, starts, renews, releases, finishes, reads its roster** | eight statements over `kalam-db` | the same eight, as `/v1/runner/*` routes in the `soma` package, run as `runner_gate` (N7, N17) |
| **Where the terms of play come from** | `[vars]` | the claim response, assembled from the row's own season (N18) |
| **Who signs the replay PUT** | the replica | the gate, for a key it derives from the claim it issued |
| **Who reaps** | its own claim run, and the gate | the gate |

`db` is kept as the rollback until `api` has soaked, and then deleted ([`decisions.md`](decisions.md)
§5, N10).

**The gate is a skin over statements, not a coordinator.** Each route runs one statement from
`soma/docs/schema.md` §4, moved unchanged, with three additions made visibly: `live_runners` joined
**inside** the statement — a guard task would fail open — an in-flight ceiling per runner, and
`played_by`. It holds no assignment table and remembers no runner between calls, so work still
divides by `SKIP LOCKED` and recovers by the lease. Pull-plus-lease cannot tell a vanished runner
from a slow one and does not need to; an assigning coordinator would need a liveness model and a
rebalancer, and would put back the call R8 deleted.

**Authentication** is an admin's hashed runner key, exchanged at `POST /v1/runner/token` for a
ten-minute `aud: runner` JWT (N6, N8). A runner registers itself; revoking its key, revoking the
machine or demoting its owner ends its **next call**. The token route is rate limited per caller
address, and that — not the claim — is what bounds how many machines fit behind one NAT (N9).

**What it does not defend against, deliberately.** Operators are admins (N1), so a runner reporting
a result it did not compute is out of scope. What the finish does refuse is what a *misconfigured*
runner produces — an engine the row did not require, a rank or a strike count no match could
produce — and it leaves the row `running` for the reap. N2 names where the work starts if runners
are ever operated by competitors.

**The bulk paths never touch Soma.** A replay goes to the object store on a presigned, per-attempt
PUT, and weights come from the public-read bucket by generated key, re-hashed against the digest.
Either one through a REST workflow would make one node the bottleneck of every match; the turn loop
stays on the runner for the same reason. [`deployment.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/deployment.md) §11 is the operator's page.

---

## 4. One match, end to end

1. A competitor names an entry, then `POST`s the hashes of **model.onnx** and **manifest.json** to
   Soma, which records the submission and answers with two **presigned PUT URLs**. They upload.
   Soma's admit clock then reads the manifest back out of the bucket, checks it hashes to what was
   declared, rebuilds the registration field by field with the platform's model id, and registers it
   on its own node by reference and digest. The node fetches the object, re-hashes it, reads the
   graph — parameters, nodes, operators, opset — and probes it; the clock activates it, plays it
   over the game's reference observations through the `tb-probe` channel, applies the season's
   policy to what came back, and archives it again. Soma records the verdict: the version is
   verified and waits for its trial, or is rejected with the reason a competitor reads.
2. Soma's clocks run, each a cluster-wide singleton on its own key, each fenced, none waiting for
   another. **Count** runs as often as results arrive: every `finished` row not yet marked is folded
   into ratings in finish order and marked, and a finished trial row is decided as it is reached. A
   candidate that played without forfeiting is promoted in two statements — the first bumps the
   roster fence, supersedes the predecessor, activates the candidate and seeds its ratings from the
   predecessor's; the second withdraws the predecessor's queue. A candidate that forfeited, or whose
   row failed with a fault attributed to its seat, is rejected with the reason. **Pair** runs at the
   rate the queue drains: it reads the **demand view** — how many matches the ladder wants now — and
   inserts up to the smaller of that and the room under the depth target, choosing for each the
   opponents and the maps that would teach the ladder the most, and stamping each row with the engine
   digest the deploy has declared current. A verified version with no live trial row gets one,
   against a baseline, counting for no ladder. **Withdraw** runs every minute or so as the backstop.
3. Meanwhile each replica's **roster clock** has registered, admitted and activated every verified
   or active version on its own node — one step per version per tick, reading the shared schema and
   nothing else. A Kalam replica then claims ONE row, trial rows first — itself, or through the
   gate, which answers with the terms the row's season sets; asks its own admin API whether it can
   serve both seats' models, releasing the row if not; and asks the game engine plugin for the world
   from the row's seed.
4. Each turn: the engine observes every live seat; **one `model_infer` per seat** evaluates that
   competitor's adapter under `engine.ops_budget`, runs their graph under `tract` inside
   `timeout_ms`, and hands back the policy tensor; the workflow decodes the head — gathering at the
   ants' cells for a per-cell head, or reading a per-ant one straight — and the engine steps. A seat
   whose call failed or timed out gets the no-op and a strike. Every N turns the replica renews its
   lease in one statement on the database's clock, and halts if the renew touches nothing. Through
   the gate that is `applied: false`; a call that never arrived is not the same failure, and the
   match plays on.
5. When the match ends: the engine scores; a seat that forfeited ranks last; the replica writes the
   replay blob under a key that names the attempt — to a URL the gate signed, in `api` mode — then
   finishes the row with the result and the key in one statement. A finish delivered twice answers
   `applied: false` and is a success; a claim that is really gone answers `409`. There is nothing to
   release — the session stays warm in the node's LRU cache for the next match that needs it. **It
   has read no rating and written none.**
6. On count's next run the match is counted, and the row carries the rating change.
7. The leaderboard is a read over ratings. A competitor's Version screen lists a match, trial or not,
   the moment its row is `finished`, and shows the rating change once it is `rated` — at most one
   count period later.
8. The competitor's next version plays its trial, and on count's next run passes it and is promoted
   as step 2 describes. The predecessor's claimed and running matches finish and count against it. On
   pair's next run the successor is paired for the first time, and the opponents from the withdrawn
   rows are paired again.

**Step 2 is the only place the ladder is written, and the only place a version is promoted.** Steps
3 to 5 know nothing about ladders.

---

## 5. What must stay true

These are the system-wide invariants. Each repository's README §9 carries its own slice, rewritten
so it can be checked against a diff.

1. **The database is the only coupling.** No broker, no queue service, no HTTP between Orion
   instances. If two parts need to talk, one writes a row and the other reads it. Beside the gate,
   the one HTTP call a package makes is to **its own node's admin API**, over loopback, never
   another node's — which is what lets a replica keep its own model registry without anyone telling
   it to. **The gate is not a second coupling**: its routes are the statements a `db`-mode replica
   runs itself, and it adds no state, no assignment and no ordering (§3a).
2. **Every part but the database is disposable.** A Kalam replica has no shared Orion state: its
   definitions and plugins are baked into its image, its own Orion state can be a local SQLite
   file, it drains on SIGTERM, and a crash loses only the match it was playing.
3. **Each of Soma's clocks is a singleton by lock on its own key, and correct without one.** Every
   ladder and roster write carries a fence: the run's fence for count, the roster fence for pair
   and promotion, the mark on the row for the match. A stale run writes nothing and halts; a
   second pair is fenced out; a withdraw is idempotent. **The locks buy efficiency and ordering;
   the fences buy correctness.** Soma scales by load, so this is not hypothetical.
4. **A match is finished once, at the end, idempotently.** The claim token makes a stale attempt a
   no-op and the replay key names the attempt, so re-playing a match is always safe.
5. **Ratings have one writer, Soma's count clock, applying matches in finish order** — and seeding a
   promoted version, since count is what promotes. Kalam never reads or writes a rating row, and
   neither the `kalam` role nor `runner_gate` can. Because of that, how many matches a model version
   plays at once has no bearing on whether ratings are right — only on how they are paired.
6. **The adapter is data, and it runs in a sandbox.** It is a competitor's code in all but name:
   evaluated by **datalogic** under `engine.ops_budget` — the operation count the game's manifest
   publishes — inside a `timeout_ms` the node caps, and it may read no secret, no clock and no
   randomness. It is never definition content.
7. **Nothing outside the game engine parses game state.** Kalam carries it as an opaque value
   between calls, and an adapter sees only the per-seat observation the engine hands out. The one
   exception is deliberate and named: the platform decodes the **policy head**, because a manifest's
   `result` expression sees the output tensors and not the observation, so it cannot gather at the
   ants' cells. That decode is game rules, and it lives in Kalam's workflow and the CLI alike.
8. **Scaling signals are queries.** The demand view drives the Kalam replica count up, and the age
   of the oldest `pending` row guards latency. Drain by SIGTERM means scaling down loses nothing.
   Nothing needs a metric pipeline to scale.
9. **A trial is an ordinary match** that counts for no ladder. It is claimed first, played, listed
   and replayable like any other; count marks it without touching a rating, and decides it.
10. **The two Orion packages share no workflow.** They share one schema and one Orion version,
    promoted together. A row records the engine digest and the Orion version that played it, and is
    claimed only by the engine it requires.
11. **A queued match is a promise only while its seats are contesting and its engine is current.**
    What is already claimed finishes and counts against the version that was paired: **the ladder
    records what was played, not what is current.**
12. **A runner holds no credential that can write the platform** — no connection string, no bucket
    write key, no admin token. Configuration that hands an `api` replica more still works, which is
    why `devops/scripts/check/configs.sh` §1f refuses it rather than trusting it.
13. **The gate's statements are Soma's.** A route is a skin over a statement in
    `soma/workflows/soma-runner-*.json`, and `soma/scripts/verify/run.sh` refuses to run when its
    copy differs. Kalam's `db`-mode copies are the rollback and leave with it; nothing else may grow
    one. **Do not widen the `kalam` role to make a route work** — a route that needs a grant is on
    the wrong connector.
14. **The gate mints the claim token, and the lease is the database's clock.** A runner never sends a
    timestamp, and `live_runners` is joined inside every statement, never checked in a guard.
15. **`finish` is idempotent under a duplicate delivery and fenced against a stale one, and the two
    answers differ.** A route that conflates them fails a healthy runner mid-match.
16. **A match is played under its own season's terms.** The contract is read `coalesce(season rule,
    games.manifest.limits)` off `matches → seasons`, so closing a season or rebuilding a cartridge
    cannot change a queued match; `renew_every_n_turns` is derived from `turn_ms` and the lease
    rather than declared; and `GET /v1/games/{game}` serves the same effective limits, or the site
    states a turn budget the ladder does not play by.

---

## 6. Why each part is on Orion, and what that costs

Soma and Kalam are definitions — channels, workflows, connectors — rather than application
code, because the platform's work is overwhelmingly *shaped like* what Orion already does: receive a
request, run a sequence of steps against a database and an HTTP service, and do it again on a
schedule under a singleton lock. What would otherwise be three services with their own HTTP
plumbing, their own schedulers, their own retry and their own observability is instead two
packages of JSON, and the operations console reads all of them.

The costs are real and are paid deliberately:

- **No arbitrary computation in a definition.** Anything that is genuinely an algorithm — rating
  math, pairing math, the game itself — is a WebAssembly plugin. This is the constraint that shaped
  the seam, and it is the sentence that used to end "and it is why Axon is a binary". It no longer
  does: since Orion 1.8.1 the model *is* a governed entity of the runtime, with the adapter as
  JSONLogic priced by the same budget as every other expression, so the fourth algorithm moved
  inside rather than beside.
- **Debugging is reading traces, not stack frames.** The console is the debugger.
- **The version of orion-server is a deployment fact**, and a package that lints against one may not
  against another. `devops/` pins it; the packages do not.

What the platform gets back is that every schedule, every retry, every quarantine and every trace
is the same mechanism in all three packages, and that a new game is a plugin rather than a service.

---

## More

- [`decisions.md`](decisions.md) — the decision log, and the reasoning behind each
- [`deployment.md`](deployment.md) — topology, drain, cluster mode, the digest declaration
- [`orion-notes.md`](orion-notes.md) — the Orion facts the build had to discover
- [The competitor guide](https://github.com/Tiny-Brains/web/tree/main/docs) — the reader-facing half
