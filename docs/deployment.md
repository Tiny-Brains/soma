# Deployment and scaling

> **Moved from `devops/docs/` on 17 September 2026**, when devops stopped running anything (N25).
> The page was split by the repository each section is about, and every section keeps the number the
> whole page gave it, so a citation of *§9* still resolves — in the repository that section now
> lives in. §4.2, §6, §7, §8.2 and §11 — a replica's cluster rule, drain, its numbers, its roster and a runner on
> a desk — are [kalam's](https://github.com/Tiny-Brains/kalam/blob/main/docs/deployment.md).
> It was written before N25: where it describes in-cluster Kalam replicas, a loader, an Orion image
> devops built or `docker-compose.fleet.yml`, the platform now runs a Soma node image, runners from
> kalam's compose file, and web's `docker-compose.yml`.

How TinyBrains is deployed: the fleet, the two Orion configs, cluster mode, the autoscaler, drain,
the loader on both sides, the database roles, the deploy order and retention.

The system map is [`architecture.md`](architecture.md); the reasoning behind the numbers is
[`decisions.md`](decisions.md), which carries decisions 5, 25 and 41 to 45 from this page.

## 1. What this page fixes

| Settled | Left to |
|---|---|
| the fleet: three deployment units and what each one is (§2) | the orchestrator — Kubernetes or Cloudflare Containers — which this page deliberately does not choose (§13.1) |
| the config split: one template becomes two, and the rule for which `[vars]` section goes where (§3) | a `policies` table — versioned, immutable, read in the run that acts on it — the day a number must change without a redeploy |
| **Soma — routes and clocks — in cluster mode**, and why that is a requirement rather than a scaling choice (§4.1) | the replica count for Soma, which is an availability number and not a load one |
| **Kalam not in cluster mode**, and why that is a correctness requirement rather than a saving (§4.2) | — |
| the drain: which of the four numbers actually bounds a wave, corrected from source (§6) | the measurement that confirms it on a real replica (§14) |
| the autoscaler's query, and why it reads demand and never queue depth (§5) | the orchestrator's scaler API, and the reconciliation period |
| **decision 5** — K as a residency budget rather than a measurement (§7.1) | the class mix a real fleet serves |
| **decision 25** — the poll interval's shape, with its constant still owed to the spike (§7.2) | the claim-under-load spike |
| the loader beside every replica and once beside Soma; S3/R2 as the third store (§8) | asynchronous load, which stays out until a cold large model measurably hurts |
| the deploy step: the order, and the engine digest as the cutover switch (§9) | — |
| a runner on hardware this deployment does not own: what it holds, what to pin, and how to read the Runners screen when one is wedged (§11) | the machine, and whether to trust whoever owns it |
| the Kalam role's password in a deployed database (§10) | a role for the clocks: they had `jodi` until 16 September 2026 and run as the owner since, by decision (§10) |
| TLS, `admin_auth`, the trust keys, and what each one gates (§12) | minting the keys, which is an operational act |
| retention made real: the bucket lifecycle rule and Orion's trace retention (§12) | — |

---

## 2. The fleet

**TWO deployment units** since the 1.8.1 rebuild, and the parts that are not Orion. The third was
`axon`, and inference is Orion's own now (decision R1).

```
                    ┌──────────────────────────────────────────┐
   browser ───TLS──▶│  soma       — Orion, CLUSTER MODE, N≥2   │
                    │  REST + four cron clocks + tb-probe      │
                    │  [models] ADMISSION ONLY                 │
                    └───┬──────────────────────┬───────────────┘
                        │                      │
                        │               ┌──────▼───────┐
                        │               │  Redis       │  cluster: dedup,
                        │               │              │  caches, rate limits
                        │               └──────────────┘
   ┌────────────────────▼───────────────────────────────────────┐
   │  Postgres (managed) — TWO databases                        │
   │    soma         the match schema, one migration set        │
   │    orion_state  Soma's Orion state, cluster-shared         │
   └────────────────────▲───────────────────────────────────────┘
                        │
   ┌────────────────────┴───────────────────────────────────────┐
   │  kalam × N — one Orion EACH, single instance, local SQLite │
   │  ┌──────────────┐ ┌──────────────┐      ┌──────────────┐   │
   │  │ orion+tb.ants│ │ orion+tb.ants│ ...  │ orion+...    │   │
   │  │ [models] PLAY│ │ [models] PLAY│      │ [models] PLAY│   │
   │  └──────────────┘ └──────────────┘      └──────────────┘   │
   └────────────────────────────────────────────────────────────┘
                        │
                 ┌──────▼──────┐
                 │  R2         │  the MODELS bucket (by version id) AND the replay bucket
                 └─────────────┘
```

| Unit | What it is | Scales on |
|---|---|---|
| **soma** | one Orion in cluster mode, N ≥ 2 behind a load balancer, over the shared `orion_state` database and a Redis. Serves the fourteen REST routes and runs the four cron clocks | availability, then request rate. Never on match volume — the clocks are singletons whatever N is |
| **kalam** | N Orions, each a single instance with its own local SQLite state and its own model registry, kept in step by its `tb-roster` clock. No load balancer, no route, no shared state | **the demand view** (§5) |

**The parts that are not Orion**: managed Postgres, a Redis, and R2 — the models bucket *and* the
replay bucket, over one credential. **The models bucket needs two addresses**: the one a node dials
(`MODELS_ENDPOINT`) and the one a competitor's presigned upload is signed for
(`MODELS_PUBLIC_ENDPOINT`). In a deployment they are usually the same public R2 endpoint; on a
laptop they are not, and a single value there is a URL only one side can use.

**What each unit must not become.** Kalam replicas must never share Orion state (§4.2). Soma
must never run outside cluster mode at N > 1, because the four clocks would each run N times. Those
are the two ways this topology is wrong rather than merely mis-sized.

---

## 3. One template becomes two

Until this page, `devops/orion/orion.toml.tmpl` was one file with one `[vars]` block sectioned by owner, and
its header already says why: *"the day devops gives a package a server of its own, its section
moves with it and nothing in the package repos changes."* This page is that day.

| New file | Holds | `[vars]` sections |
|---|---|---|
| `devops/compose/orion/soma.toml.tmpl` | `data_mounts`, `[cluster]`, `[storage]` on Postgres, `[plugins]` for the clocks' two, `[cron]` | **SOMA** and **CLOCKS**, verbatim |
| `devops/compose/orion/kalam.toml.tmpl` | no `data_mounts`, no `[cluster]`, `[storage]` on local SQLite, `[plugins]` for `tb.ants`, `[cron]`, `[engine]` | **KALAM**, verbatim |

The sections move unchanged. What the split creates that one file could not have is **a value in two
places that must agree**:

| Value | In both because | What a disagreement does |
|---|---|---|
| `prior_mu`, `prior_sigma` | Soma's season create seeds carried baselines; Soma's count clock seeds at promotion | two priors on one ladder. One `[vars]` value in one file, so this one is safe — noted because it stops being safe the day the routes and the clocks run on two servers |
| `engine_digest` (Kalam) = `games.active_engine_digest` (the deploy) | the claim filters on it | the match clock claims nothing, for ever. §9 |
| `model_prefix` (both) | a replica registers `tb.v<uuid>`; a match row names one | the roster barrier never passes, and every row is released as `MODEL_UNAVAILABLE` |
| `orion_version` (both) | admission records which Orion judged a version; a match records which one played it | the re-validation sweep either never fires or fires on everything |
| `[engine] ops_budget` (Kalam) = `adapter_ops_max` (the game) | admission prices an adapter under one; play refuses it under the other | a competitor forfeits every turn for a ceiling nobody published |

**And one value that must NOT be in two places.** The strike ceiling is pinned onto
`matches.strike_ceiling` by pair and read off the row (decision 54), so a trial is judged by the
rule it was played under. `forfeit_strikes` stays in Soma's template as pair's fallback when a
season declares none; Kalam's template must not set a `strike_ceiling`, and the check asserts the
absence.

**The check is a script, not a convention.** `devops/scripts/check/configs.sh` parses both templates
with the defaults applied and asserts every equality above, and it runs in the deploy before either
config is shipped. A rule that lives only in a comment is one rebase from being wrong, and the
failure mode of each of the three is silence.

Each package's `scripts/load-package.sh` already lists what the deploying config owes it, so the
script has something to check against on each side.

---

## 4. Cluster mode

### 4.1 Soma: a requirement, not a scaling choice

Orion's cluster mode needs two shared backends and refuses to start without them: **Postgres or
MySQL** — `sqlite:` is refused, a file being single-host by construction — and **a shared Redis**.

```toml
[cluster]
enabled = true
redis_url = "env://REDIS_URL"
epoch_poll_interval_ms = 2000
instance_id = "${INSTANCE_ID:-}"      # stable per replica; also the Kafka group.instance.id

[storage]
url = "env://ORION_STATE_DB_URL"      # the orion_state database, NOT soma
auto_migrate = false                  # §9; a cluster with it true is REFUSED at startup
```

The reason it is not optional is the clocks. **A `forbid` singleton is a row exactly one occurrence holds
at a time, acquired in the same transaction that marks it running** — Orion coordinates cron
entirely through its state tables and needs no leader. Cluster-wide is therefore the same thing as
*state-database-wide*: two Orions over one `orion_state` are one scheduler, and two Orions over two
are two schedulers. Run Soma at N = 2 without cluster mode and you get two `tb-count` clocks folding
the same finished matches, which the fence in `clocks` would make *safe* but not *once*.

Three things change for Soma on the way in, all of them improvements:

- **The six `principal_rate_limit` channels become fleet-wide.** Per-channel rate limits live on the
  shared Redis in cluster mode, so `10 rps` on `/v1/me` is 10 rps across the fleet rather than 10N.
  That is what the number always meant. No channel changes.
- **A config change through any node reaches all of them**, which is what makes
  `load-package.sh` against one replica a fleet-wide install (§9).
- **`/health` gains `config_propagation`.** `degraded` means a bump failed and peers may be stale.
  Alert on it and on `orion_errors_total{reason="config_epoch_bump"}`.

Two costs to size for. `max_concurrent_per_node` is per node, so N replicas admit N× that many in
flight; and platform `[rate_limit]` IP limits stay per node, N× the configured value fleet-wide —
which is the opposite of the channel limits above and is easy to get backwards.

**One trap that does not apply, checked rather than assumed.** A channel whose *deduplication* or
*cache* connector is missing, broken, or explicitly in-memory refuses to load in cluster mode and is
quarantined — served as `503`, absent from the route table, listed under `/health`. None of Soma's
thirteen channels declare either; the six that declare anything declare `principal_rate_limit`,
which is not in that set. Soma goes cluster with no channel edits. This is worth having checked,
because the failure is a live endpoint becoming a `503` on a config change nobody associates with it.

## 5. The autoscaler

**It reads demand, and it must never read queue depth.** The reason is arithmetic and it is a trap
worth stating before the query: pair inserts `least(sum(want), pair_depth_target − depth)`, so the
pending queue **cannot exceed `pair_depth_target`**, which is 64. At K = 16 a scaler that read depth
would ask for at most four replicas no matter how much the ladder wanted, and would look correct
while capping the fleet. The depth target is a staleness cap on pairings, never a signal.

Demand also **leads the queue**, which is the answer to the risk register's "autoscaling lag against
match duration": the demand view says what the ladder wants before pair has inserted it, so a
replica is asked for before the rows it will claim exist.

`$1` game · `$2` burst · `$3` steady cap · `$4` settled sigma — the demand view's own parameters,
02 §4 — and `$5` K · `$6` floor · `$7` ceiling · `$8` the latency guard in seconds:

```sql
WITH demand AS (
    -- the pair clock's demand view, verbatim, scoped to the live season by the season scope
    ...
), q AS (
    SELECT count(*) FILTER (WHERE m.status = 'pending')                          AS depth,
           count(*) FILTER (WHERE m.status IN ('pending','claimed','running'))   AS outstanding,
           coalesce(extract(epoch FROM now() -
                min(m.created_at) FILTER (WHERE m.status = 'pending')), 0)       AS oldest_pending_s
      FROM matches m
      JOIN seasons s ON s.id = m.season_id AND s.closed_at IS NULL
      JOIN games   g ON g.id = m.game_id  AND g.slug = ($1)::text
     WHERE m.engine_digest = s.engine_digest      -- rows of the CURRENT engine only; §9
), want AS (
    SELECT coalesce(sum(want), 0) AS want FROM demand
)
SELECT want.want, q.depth, q.outstanding, q.oldest_pending_s,
       least(($7)::int, greatest(($6)::int,
           ceil((want.want + q.outstanding)::numeric / ($5)::int)::int
         + CASE WHEN q.oldest_pending_s > ($8)::int THEN 1 ELSE 0 END
       )) AS replicas
  FROM want, q
```

**Why the numerator is `want + outstanding`.** `outstanding` is every match row the current engine
still owes work on; `want` is what the ladder wants *beyond* what is already in flight, since the
view's `want` is `greatest(cap − in_flight, 0)`. Their sum is the work the fleet must hold, and a
replica holds K of it, so `ceil(…/K)` is the fleet that drains it in one wave.

**The latency guard is a nudge, not a jump.** One replica above the computed target while the oldest
pending row is older than `$8` — it catches the case the arithmetic cannot see, a row nothing is
claiming because the fleet is busy elsewhere, without turning a single stuck row into a fleet.

**The `engine_digest = s.engine_digest` predicate is what makes a rolling deploy not oscillate.**
Mid-deploy the old engine's rows are being drained by replicas that are going away; counting them
would ask for new-engine replicas to cover work they cannot claim. §9.

**Driven, 8 September 2026.** `scripts/check/autoscale.sh` substitutes the pair clock's demand view --
verbatim out of `tb-pair-run.json` -- into the skeleton above and runs it over six staged ladders in
a scratch copy of the real database. All four claims hold: want is 6 with the queue still **empty**,
so demand leads it; a queue pinned at `pair_depth_target` = 64 asks for **5** replicas rather than
the 4 a depth-reading scaler would cap at; the latency guard takes 5 to **6**, exactly one, when the
oldest pending row is 600 s; and 40 rows on a retired engine are counted as **zero**. What is not
driven is the loop itself, which needs an orchestrator to close.

**Sizing the loop.** The reconciliation period must be above the scale-up latency — a replica's boot
plus its package load plus its first model fetch — or the scaler acts on a fleet it has already
asked for. Below the wave duration, or it never sees the effect of the last decision. Both bounds
are deployment facts; the period is not a number this document can pick.

---

## 8. Models, on both sides

### 8.1 One bucket, two addresses, and the node fetches

**There is no loader process.** Each node runs Orion's own `models` entity: a model row carries a
manifest and an artifact reference — `{connector, key, digest}` — and the node fetches the object
through a storage connector, **re-hashes it against the declared digest**, reads the graph, probes
it, and afterwards serves `model_infer` from an LRU session cache. The soma node does this for
admission; each replica does it to play.

**Every node must read one bucket, and in a fleet that means R2.** The competitor uploads to
`models/<version_id>/model.onnx` and `manifest.json` through a presigned PUT Soma mints; admission
reads the manifest from there and the node fetches the artifact from there; every replica fetches
the same object by the same digest. Two buckets would mean a version admitted on one node cannot be
played on another — quietly, and a long way from the cause.

**The bucket needs two ADDRESSES, and this is the part that bites on a laptop.** SigV4 signs the
host, so a URL signed for `minio:9000` is one only a container can use and a URL signed for
`127.0.0.1:9000` is one only the host can use. `MODELS_ENDPOINT` is what a node dials and
`MODELS_PUBLIC_ENDPOINT` is what the competitor's upload is signed for; in a deployment both are the
same public R2 endpoint and the second can go unset. Getting this wrong fails as an **SSRF refusal
at the `head` stage** that names an internal IP and neither variable.

**A storage connector is SSRF-checked like any other.** A compose service name resolves to a private
address, so `load-package.sh` sets `allow_private_urls` on `soma-models-internal` and `kalam-models` under the
same flag the database connectors use. It is deployment, not package: the committed connector never
ships the guard off.

**THE MODELS BUCKET NEEDS A CORS RULE, because the upload is a browser now.** `/submit` reads the
two files, hashes them with `crypto.subtle` and `PUT`s them to the presigned URLs from the page, so
the object store sees a cross-origin request from the site and is asked for a preflight first. MinIO
answers one by default, which is why the dev stack works with nothing configured; **R2 and S3 do
not** — an unconfigured bucket refuses the `OPTIONS` and every competitor silently falls back to the
`curl` commands the page prints. Allow `PUT` from the site's origin, with no headers to allow
beyond the default, and no credentials:

```json
[{ "AllowedOrigins": ["https://tinybrains.dev"], "AllowedMethods": ["PUT"], "MaxAgeSeconds": 3600 }]
```

Nothing else changes: the URL is still one-shot, still signed for `MODELS_PUBLIC_ENDPOINT`, and the
platform still re-hashes what arrives. **Verify it from a browser and not from `curl`** — `curl`
sends no `Origin` and so never exercises the rule that is missing.

**What the digest buys.** A row that lies about its bytes fails admission at the `digest` stage
rather than playing something else, and it fails on **every** node independently — the verdict is
shared inside a cluster, the bytes never are.

## 9. The deploy step

**One migration set, one loader artifact, both packages, promoted together** — the review decision
B′, and the reason the digests on the row exist is to make a skew visible when it is not.

The order is not arbitrary. Each step is safe against the fleet as it stands when it runs:

| # | Step | Safe because |
|---|---|---|
| 0 | `orion_state` exists | `CREATE DATABASE` is not something `migrate` does, and a cluster-mode node cannot start without it. Locally this is the `db-bootstrap` service, which runs before either Orion and is idempotent; in a deployment it is the orchestrator's own init step |
| 1 | `orion-server migrate` on `orion_state` | `auto_migrate = false` is required in cluster mode — a cluster left on `true` is refused at startup, and a replica booting against a pending migration fails fast |
| 2 | the `soma` schema's migrations | additive only. **The schema is pre-release today and `0001_init.sql` is rewritten in place; the day it releases, this becomes expand/contract** — ship the add, run both shapes, remove the old shape a release later. Old and new binaries share one database during any roll. Locally `db-bootstrap` applies them only into an EMPTY database and records `sha256` over them as `tinybrains.schema_digest`, refusing a rewrite it cannot apply rather than letting it surface as a missing relation on a cron tick |
| 3 | *(gone with Axon)* — the Orion version is promoted with the image, and `orion_version` on a row records which one played it |
| 4 | `load-package.sh` for soma, against **one** cluster node | a config change through any node reaches all of them (§4.1) |
| 5 | the new Kalam replicas, each loading its own package | they claim **nothing** yet — every row of the season names the old digest |
| 6 | **declare the engine digest** | the cutover |
| 7 | the old replicas drain | they claim nothing new; withdraw retires what is left |

**Step 6 is the switch, and it is one statement.** Layer 06 §5.3's patch, run only once the new
replicas exist — finding 5 option A, and the reason the deploy declares rather than the server
advertising:

```sql
WITH g AS (
    UPDATE games SET active_engine_digest = ($2)::text
     WHERE id = ($1)::uuid AND active_engine_digest IS DISTINCT FROM ($2)::text
 RETURNING id
), s AS (
    UPDATE seasons s SET engine_digest = ($2)::text
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL AND s.engine_digest <> ($2)::text
 RETURNING s.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM s WHERE c.key = 'roster'
```

Before it, the new replicas are idle and the old fleet is playing. After it, pair stamps the new
digest, the new replicas claim, and the old ones can claim nothing — they drain what they hold.
Withdraw cancels every `pending` row still naming the old digest as `ENGINE_RETIRED` within the
minute, and pair re-inserts on the new one. **No engine mixes into a ladder at any instant**, which
is the rolling-deploy requirement, and it holds without a deploy pause or a deactivation step.

**One change from what the local loader does.** It re-stamps `pending` rows onto the new digest as a
kindness to a dev stack. A deployment should not: let withdraw cancel and pair re-insert. The
pairing was chosen for the old engine and the ratings have moved since; a fresh insert is a fresh
pairing, and it costs one withdraw period.

**A release, not a patch, is refused while a season is live** — 06 §5.3, zero rows, and the loader
fails loudly. The operator rolls back or asks the admin to close the season. This is already built.

---

## 10. The Kalam role

Layer 01's migration creates the role with `LOGIN` and no password and grants it `SELECT` on
`matches` and `match_seats` and `UPDATE` on exactly its own columns, so the committed schema ships
no secret and the grants come free with step 2 above. What does not come free is the password:

```sql
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
```

from the orchestrator's secret store, not from a compose default. `kalam/scripts/check-sql.sh`
already asserts the grants cover what the wave writes and no more, and `soma/scripts/check/claim-load.sh` proves
Postgres refuses it everything else; both should run against the deployed database once, as a
deploy-time assertion rather than a local one.

**Decided, 16 September 2026: the clocks run as the owner.** They had a `jodi` role of their own —
no DELETE anywhere, nothing on `sessions`, no UPDATE on `models` — from 8 September until the clocks
merged into the soma package, and the role went with the repository: one package, one reload, one
`soma-db` connector. What still confines them is `soma-db`'s `operations.delete = false` and review.
The runner routes are the opposite case, and kept a role (`runner_gate`), because what they confine
is a machine outside the deployment rather than a clock inside it.

---

## 12. Security, and what each item gates

Each of these is a precondition for something, and naming which is what stops them being a list
nobody finishes.

| Item | Gates |
|---|---|
| **TLS**, and `cookie_secure = true` with it | any origin that is not loopback. Browsers will not store a `Secure` cookie from `http://`, and Orion refuses a non-https `oauth_redirect_uri` off a loopback host at load — so this is not optional, it is the first thing that must be true |
| **`admin_auth` on the Orion admin API** | the admin plane becoming reachable off loopback at all. Locally the port is bound to `127.0.0.1`; in a fleet the loader must reach it across the network, which is precisely when it stops being safe unauthenticated |
| **Ed25519 trust keys**, `[plugins.trust] public_keys` non-empty | `tb-ants` signed, verified at every load. It is the one place a third party's code enters the platform — so it must be non-empty **before** a second cartridge by an outsider ships |
| **R2 credentials**, two grants over one account | §8.1. The admission role writes the model store; replicas read it; Soma presigns replay `GET`s and Kalam presigns `PUT`s |
| **A Redis of its own for the response cache**, or at least a logical DB | Soma's nine cached read channels. Compose puts the cache on db 1 and the cluster state on db 0, so a cache key cannot collide with a singleton row — but they are one instance and one memory budget, and there is no `maxmemory` policy that could trim the cache without also evicting the coordination the clocks depend on. Bounded today by TTLs of 10–300 s rather than by a policy |
| **`[rate_limit] trusted_proxies`**, narrowed to the proxy actually in front | every per-channel `rate_limit` Soma declares. Orion reads `X-Forwarded-For`/`X-Real-IP` **only when the direct peer is in this list**, and otherwise keys on the peer — which is nginx, so an empty list rate-limits the whole internet as one address. The section is here for this key alone; `enabled` stays `false`, because the platform-wide limiter is a different control and the trust list is not gated on it. Trusting a range wider than the proxy is the other failure: anything inside it can claim to be any address |

**The property to keep, not a task**: the evaluator is the only place competitor logic runs, and
never as definition content. Nothing in this page moves it.

---

## 13. Retention made real

Layer 06 §7's policy table says what is kept; this page is where two of its rows stop being policy.

| Row | Kept | Mechanism |
|---|---|---|
| standings | for ever | the `seasons` and `ratings` rows. Nothing to build |
| match rows | indefinitely | nothing to build; revisit when vacuum shows it — deferred by design until then |
| **replays** | by a bucket lifecycle rule | an R2 lifecycle rule on the `replays/` prefix. Layer 06 §7's evictable-hash query is what says which are safe to sweep |
| **traces** | Orion's own retention | `[trace_storage]`. `sync` mode is right at Soma's volume; the five cron channels already carry `errors_only`, so a clean wave writes nothing |
| model store | by the same query | the evictable-hash query names weights held only by closed seasons' rejected rows |

---

## 14. What this page deliberately does not decide

### 13.1 The orchestrator

Kubernetes and Cloudflare Containers behind a Worker are both viable and the design does not depend
on which. Everything above is expressed as *the orchestrator's grace period*, *the scaler's target*,
*an init step* and *a secret store*, because those are the four things any orchestrator has. Orion
ships a Helm chart that deploys the cluster shape — 2 replicas, a pre-upgrade migration Job, surge
rolling deploys, a PodDisruptionBudget — and that is the shortest path for the soma unit if
Kubernetes is chosen. **Choosing is an owner decision and a cost question, not a design one.**

### 13.2 Soma's replica count

An availability number. Two survives a rolling deploy and a node failure, which is the requirement;
load is nowhere near a single instance's measured ceiling and the clocks do not care.

---

## 15. What is verified, and what is not

**Verified — read out of Orion 1.7.0's source and documentation, not assumed:**

- cluster mode refuses `sqlite:` and requires a Redis; `auto_migrate = true` is refused at startup in
  a cluster (`docs/src/operate/cluster.md`);
- a `forbid` singleton is a row in the state database, held by one occurrence at a time, so
  cluster-wide means state-database-wide — §4.1 and §4.2 both turn on this;
- the supervised-task drain, which contains the cron worker, is bounded by
  `server.shutdown_force_timeout_secs` and not by `cron.shutdown_timeout_secs`
  (`crates/orion-server/src/main.rs`, `runtime/tasks.rs`, `cron/worker.rs`) — §6.1;
- `shutdown_drain_secs` is an unconditional `sleep` (`server/serve.rs`), a fixed period;
- a cancelled cron attempt's claims and singleton rows are left to expire deliberately, never
  released eagerly (`cron/worker.rs`) — §6.2;
- strict-mode quarantine is reached only through a **cache connector** — the dedup store and the
  response cache — and is refused for `backend == "memory"` or a missing connector
  (`channel/registry.rs`). Soma declares neither, so none of its thirteen channels can be caught
  by it;
- `build_limiter` picks `RedisRateLimitBackend` whenever `cluster_redis` is present and
  `LocalRateLimitBackend` otherwise, and **`principal_rate_limit` goes through the same builder as
  `rate_limit`** (`channel/registry.rs`) — so Soma's six quota channels become fleet-wide on the
  strength of `[cluster] redis_url` alone, with no channel edit — §4.1.

**Driven on the local stack, 8 September 2026** — the split is built, and these ran:

1. **The config split (§3).** `orion.toml.tmpl` is now `soma.toml.tmpl` and `kalam.toml.tmpl`, each
   parsing through `orion-server validate-config`. `devops/scripts/check/configs.sh` asserts the
   three cross-file values and the four structural rules, and passes.
2. **Cluster mode (§4.1).** Soma runs with `[cluster] enabled`, Postgres state and Redis, and
   `auto_migrate = false` with `migrate` as the entrypoint's step. All four clocks run as
   singletons under one `instance_id` with `fencing_token=1`, and `/health` reports
   `config_propagation: ok`. **No channel needed editing** — the quarantine trap is for dedup and
   cache connectors, and Soma declares neither.
3. **A replica is its own scheduler (§4.2, decision 41).** Two replicas, each with its own SQLite
   state and its own sidecar *(as it then was)*, claimed and played **two concurrent waves** — 48
   rows drained in about 50 s. Under one shared state that number would have been one wave, for
   ever. The same property now carries four `tb-match` channels per replica instead of one wave.
4. **The loop closes across the split.** 168 matches paired, claimed, played, finished and folded
   into ratings by count on the other unit.
5. **§6.1's correction, measured and confirmed.** This is the one that mattered, because the layer
   asserts it against what the build had written down:

   | `drain` | `force` | `cron` | `docker stop` returned | rows left `running` |
   |---:|---:|---:|---:|---:|
   | 5 | 2 700 | 2 700 | **16 s** | **0** |
   | 0 | **1** | 2 700 | **2 s** | **16** |

   `cron.shutdown_timeout_secs = 2700` did **not** protect the wave. The bound was
   `server.shutdown_force_timeout_secs`, exactly as `main.rs` says. And the drain ends when the wave
   ends, not at the cap: 16 s, not 2 700.
6. **The recovery path (Kalam's drain ([`kalam/docs/design.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/design.md) §5)).** The 16 abandoned rows lapsed after their 300 s lease, the
   next claim reaped them, they were replayed from turn zero, and every one reached `rated` —
   `lapses = 1`. This is what makes decision 42's small drain safe rather than merely cheap.
7. **§8.2's invisible capacity, met in the wild.** Recreating a replica gives it empty state, so it
   comes back with no `tb-wave` channel: `/readyz` green, claims nothing, nothing logged. It cost a
   confusing minute before the loader's new per-replica `tb.ants` assertion caught it, which is the
   check this page added for exactly that reason.

8. **§8.1's store, built and driven.** Every node reads the models bucket on MinIO over SigV4, and
   `devops/scripts/dev/seed-baselines.sh` writes through a signed PUT rather than `docker cp`.
   Re-verified on 14 September 2026 after the rebuild: three baselines uploaded to
   `models/<version_id>/`, registered and admitted **by each node independently** through its own
   storage connector, digest re-hashed at the `digest` stage, and matches played from them.

**Still not verified**: the autoscaler's query against a live demand view (§5); a rolling engine
deploy with two replicas on different digests — the rig
is in place now that replicas take `KALAM_N_ENGINE_DIGEST`; the SigV4 store against **real R2** as opposed to MinIO,
which is the same S3 surface but not the same service; the deploy order of §9 end to end; and the numbers in §7 other than the poll interval, which the
claim-under-load spike has now measured (§7.2).

**One honest caveat about the drain table.** The measured waves are baseline-vs-baseline matches of
a few seconds, so the second row's window had to be squeezed to 1 s to make the difference visible
at all. The mechanism is what was under test and the mechanism is confirmed; the *numbers* for a
real class mix are still this page's to set.

**What is left, cheapest evidence first**: §9's order, then §11's security, then the orchestrator.

---

## 16. Decisions taken here

Decisions **5** (K, rows per wave per replica), **25** (the poll interval), and **41** to **45**
were taken on this page. They are recorded with their reasoning and the cost of flipping them in
[`decisions.md`](decisions.md) §3, under *Deployment*.

## 17. Open questions

1. **The reconciliation period** (§5) wanted one measurement — a replica's boot-to-first-claim —
   and it has been taken on the local stack, in the three parts it is actually made of:

   | | |
   |---|---:|
   | container start → orion-server's first log line | **0.1 s** |
   | package load into the new replica | **1.4 s** |
   | worst-case wait for the next poll (§7.2) | **5.0 s** |
   | **boot-to-first-claim** | **~6.5 s** |

   The entrypoint is cheap by construction — derive the digest, migrate a SQLite file, `exec` — and
   the load is one package into an empty state. **What this does not measure is the image pull**,
   which dominates a real scale-up and belongs to the orchestrator rather than to this design; it is
   the one term a deployment has to add.

   So the lower bound is ~7 s plus a pull, and the practical floor is the pull. Against measured
   waves of 3.8–9.1 s, a reconciliation period an order of magnitude above boot-to-first-claim is
   what stops the scaler counting a replica that has not started working yet and adding another:
   **60 s is the figure the measurement supports**, and the argument for it is the ratio, not the
   number.
2. **A replica pool per weight class** is refused above (decision 45) for a real reason: the claim
   has no class predicate. If the class mix ever makes K's residency budget bind badly — a fleet
   sized for `large` wasting memory on `nano` waves — the answer is a claim predicate, and that is a
   a schema change rather than a deployment one.
3. ~~**The `jodi` database role** (§10) is owed and keeps being deferred.~~ Closed 16 September
   2026 the other way: the role existed from 8 September, and went when the clocks merged into
   Soma's package. §10 says what confines them now.
4. **Soma's routes without its clocks.** §3's table notes that `prior_mu` and `prior_sigma` are safe
   only while the two share a config. The day Soma's REST surface gets a server of its own — which
   would now be a second package compiled from the soma repository, not a second repository — that
   safety goes away and the check script has a fourth equality to assert. Worth building the check
   with the fourth case already in it.
5. **Whether `shutdown_drain_secs` at 5 s is right for Kalam** is an argument here and not a
   measurement. It rests on Kalam binding no route, which is true today. A development-only REST
   path was mounted on Kalam's config to make a cron occurrence's data readable at all
   (`build-findings.md` §4) — if that ever becomes permanent, the number changes with it.
