# The schema

The contract both Orion packages — Soma and Kalam — build against: a match row, its seat rows and
its rating events, the `clocks` table and its two fences, and every statement the clocks and Kalam
run against them, written out.

**The shipped artifact is [`migrations/0001_init.sql`](../migrations/0001_init.sql)** — one
initial schema rather than a migration chain, because nothing is released yet; versioning starts at
the first release. §3 below explains that file: §3.1 and §3.3 to §3.5 are its `matches`,
`match_seats`, `rating_events` and `clocks` definitions as they ship, while **§3.2 is written as
`ALTER TABLE` deltas against `games` and `models` that the migration has since folded into their
`CREATE TABLE`s.** Read §3.2 for what the columns and constraints are *for*; read the migration for
what runs. Every statement in §4 to §7 is exercised against Postgres 16 by
[`scripts/verify/run.sh`](../scripts/verify/run.sh) — the walk from insert to promotion, both lock
orders of both fence races, the deployed seed, and the Kalam role exercised rather than asserted.

Who writes what, and why the row is both queue and history, is
[architecture.md](architecture.md)
§3. The decisions this schema took — 2, 3, 7, 18, 21, 22 — are in
[decisions.md](decisions.md) §3.

## 1. What this page fixes

| Settled here | Left to |
|---|---|
| `match_status` and the walk between its values | — |
| every column of `matches`, `match_seats` and `rating_events`, typed, with its one writer | — |
| `models.manifest`, `models.orion_version`, the `verified` status | 04 what a manifest is; 08 what fills them |
| `games.active_engine_digest` | 07 the deploy step that writes it |
| `clocks` — the run fence and the roster counter | 02 which keys each clock claims |
| the constraints that make the status walk a fact | — |
| the indexes, and the fill factor that keeps renews heap-only | — |
| the Kalam database role and its column grants on both tables | 07 the credential |
| Kalam's statements: reap, claim, read, start, release, fail, renew, finish | 03 K, the lease, N, the refusal ceiling |
| count's statements: the fence claim, the fold, the three trial verdicts | 02 the batch, the cap, the schedule; 06 the prior and the inflation |
| pair's statements: the roster read, the fenced insert | 02 the demand view, opponent choice, the numbers |
| withdraw's statements: promotion's second, and the sweep | 02 the schedule |
| the reason words the statements in this page write themselves | 02, 03, 08 the rest of the vocabulary |

---

## 2. Orion facts the statements are shaped by

Verified against the 1.7.0 source (`crates/orion-server/src/engine/functions/db_write.rs`,
`db_read.rs`, `connector/sql_encode.rs`, `cron/metadata.rs`) and the scheduled-workflows guide.

1. **`db_write` answers `rows_affected` and nothing else** on Postgres. That number is how every
   fenced statement learns its fate: zero means the fence was lost or the row moved, and the run
   halts on it. No `RETURNING` reaches the workflow.
2. **One statement per task, and each statement is its own transaction.** The prepared path
   refuses a second statement in the string. So "promotion is two statements" means two tasks,
   and anything that must be atomic — a match and its seats — is one statement.
3. **Data-modifying CTEs are allowed in `db_write` and refused in `db_read`.** That is how one
   statement inserts a match and its seats, or marks a row, bumps a fence and seeds a rating:
   `WITH … UPDATE … RETURNING` chains, with the last `UPDATE` or `INSERT` as the main statement so
   `rows_affected` counts it. Two consequences of Postgres, not Orion: sub-statements share one
   snapshot, so a CTE cannot see another's writes on the same table; and their order is
   unspecified unless one reads another's `RETURNING`. §5.3 uses that dependency on purpose.
4. **A JSON array parameter binds element-wise** to a declared array column, and a JSON object or
   array binds to `jsonb`. The statements below bind three shapes only: `uuid[]` for a list of
   ids, `text[]` for the loader's resident hashes, and `jsonb` for a result or a set of
   posteriors, read in SQL with `jsonb_to_recordset`. An array of an enum does not bind; `ladders`
   is derived in SQL and never bound. Every parameter is cast explicitly, `($n)::type`, as Soma's
   workflows already do.
5. **`params` elements fold `{"var": …}` and nothing else.** A value that needs computing — a
   token, a key, a result document — is built in a `map` task first.
6. **`metadata.trigger`** carries `occurrence_id`, `scheduled_for` (RFC 3339, immutable across
   attempts, no two occurrences of a channel share it), `started_at`, `attempt` (1 on a first
   run) and `singleton_key` when the channel holds one. `scheduled_for` casts to `timestamptz`
   directly. The run fence is the pair `(scheduled_for, attempt)`, compared row-wise.
7. **The singleton is `transport_config.concurrency = { "policy": "forbid", "key": "…" }`**,
   cluster-wide, and a manual trigger takes the same key. `forbid` is non-overlapping, not
   exactly-once: a node that loses its lease cannot recall a statement already in flight, which
   is why every write below is fenced.

---

## 3. The schema

The initial schema for everything this page owns. `games`, `users`, `models`, `ratings` and
`sessions` stay as `0001` and `0002` have them, with the additions in §3.2. What ships is the
rewritten [`migrations/0001_init.sql`](../migrations/0001_init.sql); this section says what its
objects are for.

### 3.1 Enumerations

```sql
CREATE TYPE match_status AS ENUM
    ('pending', 'claimed', 'running', 'finished', 'rated', 'cancelled', 'failed');
```

The walk, and who may make each move — from overview §4, unchanged:

```
pending ──claim──▶ claimed ──start──▶ running ──finish──▶ finished ──count──▶ rated
  ▲ ▲ │     Kalam              Kalam            Kalam                  clocks
  │ │ └────── a seat left, or the engine retired ──▶ cancelled        clocks
  │ └──────── lease lapsed; the next claim reaps ◀──┴────┘            Kalam
  └────────── the loader refused residency; no lapse counted          Kalam
                             a third lapse, the refusal ceiling,
                             or a fault Kalam can name ──▶ failed     Kalam
```

`finished`, `rated`, `cancelled` and `failed` are permanent. Nothing here is deleted.

### 3.2 `games`, `models` and `model_versions`

**An entry and a version are two tables** (decision 51). `models` is the ENTRY — a competitor's
named lineage, keyed by that name under its owner and addressed by its id — and `model_versions` is
one submission of it. Everything a rating, a seat or a match points at is a VERSION; a rename, a
retirement and a quota are about the ENTRY.

Before the split there was one table, and "the entry" was spelled `(owner_id, game_id)` inside
seven statements. That is exactly why a competitor could hold only one: the identity had nowhere
to live but a pair of foreign keys, so every rule that should have been per lineage was per person.

```sql
CREATE TABLE models (              -- the entry
    id, owner_id, game_id,
    name,                          -- the competitor's own word for it, theirs to edit
    created_at,
    retired_at                     -- "no more versions here"; not a delete, and reversible
);
CREATE UNIQUE INDEX models_owner_game_name_uniq ON models (owner_id, game_id, lower(name));
```

**An entry is a name, and that name is the only key it has.** It used to be a GitHub
repository — `models.repo`, normalised by `repo_path()`, confirmed against `GET /repos/{owner}/{name}`
at creation, and unique per game platform-wide. All of that is gone, because **the requirement
limited nothing**: every ceiling on a competitor is a season rule (§3.11) and not one of them
mentioned a repository, while the check cost a SQL normaliser written around Orion's lack of regex,
a season predicate, two unique indexes, and an outbound call on the create path **that failed
closed** — so a rate-limited GitHub meant nobody could create an entry at all. GitHub is the
sign-in identity now and nothing else.

`models_owner_game_name_uniq` is deliberately **per owner** and not global. Two competitors may
both call an entry `ants`: a name is not an identity and nothing is decided on one, which is also
what lets `name` stay free text under `models_name_shape` — an entry is addressed by its id
(`GET /v1/models/{id}`), so the name never has to survive a URL.

It is **not** partial on `retired_at`, because retiring must not become a way to restart a version
series.

The seeded baselines **lose their special case** with it. Three of them shared
`Tiny-Brains/ants-baselines`, which was legal only because `models_repo_uniq` was partial on
`owner_github_id`; with no repository there is no shared value and no exception to explain.

`model_versions` carries what `models` used to, plus `model_id`, plus a denormalised `game_id` that
is **proved** rather than trusted: with `FOREIGN KEY (model_id, game_id) → models (id, game_id)` and
`FOREIGN KEY (season_id, game_id) → seasons (id, game_id)`, a version cannot belong to one game's
entry and another game's season — a disagreement the schema could not previously notice at all.

Every rule that was scoped `(owner_id, game_id)` is scoped `model_id`:

```sql
model_versions_model_version_uniq    (model_id, version)          -- numbers restart per entry
model_versions_one_in_flight_uniq    (model_id) WHERE status IN ('testing', 'verified')
model_versions_one_active_excl       EXCLUDE (model_id =, season_id =) WHERE status = 'active'
                                       DEFERRABLE INITIALLY DEFERRED
```

A per-USER ceiling on any of them is a cardinality over an owner's entries, not a property of one
row, so it is a season predicate (§3.11) and never an index.

**The exclusion constraint also fixes a latent bug.** Count's predecessor read is a scalar
subquery, and before the split it was scoped by owner with **no season term** — unlike `C_PASS`'s
`pred` CTE, `W_SWEEP`'s successor join and `soma-models-get`'s successor, which all had one. Since
a competitor holds an `active` version in every season they ever finished (a closed season's active
version IS its standing), that subquery would have raised `more than one row returned by a subquery
used as an expression` the first time a second season opened, and taken the count clock — and the
whole ladder behind it — down with it. Entry-and-season scoping makes it provably single-row.
`scripts/verify/scenario.sql` asserts it.

`manifest` is the Orion model manifest exactly as it was registered — `orion:model@1.0.0`, the
inputs with their adapter expressions, the outputs, `probe_dims` — as `text` rather than `jsonb`,
because jsonb normalises key order and whitespace and the stored form would no longer hash to
`manifest_hash`. Stored as text, the constraint makes the row's copy self-verifying, and its
length is the second term of the weight class (decision R4). It IS read on the play path, by every
replica's roster clock, which registers the version on its own node from this column and fetches
the artifact by digest from `artifact_key` — so the sweep, the Version screen and the node all read
one copy.

### 3.3 `matches` — one row per match, the facts that are about the match

```sql
CREATE TABLE matches (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid         NOT NULL REFERENCES games (id),
    status               match_status NOT NULL DEFAULT 'pending',
    created_at           timestamptz  NOT NULL DEFAULT now(),

    -- what to play — the pair clock, at insert
    engine_digest        text         NOT NULL,      -- the engine this row requires
    seed                 bigint       NOT NULL,
    preset               text         NOT NULL,
    seat_count           smallint     NOT NULL,      -- how many rows match_seats holds for it
    ladders              ladder[]     NOT NULL,      -- derived at insert; '{}' for a trial
    trial_version_id       uuid         REFERENCES models (id),   -- the candidate, when a trial
    pairing_id           uuid,                       -- the pairing plugin's seed

    -- who is playing it — Kalam
    claim_token          uuid,
    lease_expires_at     timestamptz,
    lapses               smallint     NOT NULL DEFAULT 0,   -- leases that expired
    refusals             smallint     NOT NULL DEFAULT 0,   -- residency refused for memory

    -- what happened — Kalam, at finish or failure
    reason               text,                       -- the engine's end reason, free text
    turns                int,
    played_ms            int,
    engine_digest_played text,
    orion_version        text,
    replay_key           text,                       -- names the attempt: …/{id}/{claim_token}.json
    played_at            timestamptz,                -- when the match ended
    fault_reason         text,                       -- on failed
    fault_seat           smallint,                   -- the seat a fault is attributed to
    closed_at            timestamptz,                -- failed or cancelled

    -- why it will not be played — the clocks
    withdrawn_reason     text,
    successor_version_id         uuid         REFERENCES models (id),

    -- what it did to the ladder — the count clock
    rated_at             timestamptz,
    rated_seq            bigint,                     -- total order of counting

    CONSTRAINT matches_seat_count         CHECK (seat_count >= 2),
    CONSTRAINT matches_fault_seat_in_range
        CHECK (fault_seat IS NULL OR fault_seat BETWEEN 0 AND seat_count - 1),
    CONSTRAINT matches_lapses_bounded     CHECK (lapses BETWEEN 0 AND 3),
    CONSTRAINT matches_status_shape
        CHECK (CASE status
            WHEN 'pending'   THEN claim_token IS NULL AND lease_expires_at IS NULL
                              AND played_at IS NULL AND closed_at IS NULL AND rated_at IS NULL
            WHEN 'claimed'   THEN claim_token IS NOT NULL AND lease_expires_at IS NOT NULL
                              AND played_at IS NULL
            WHEN 'running'   THEN claim_token IS NOT NULL AND lease_expires_at IS NOT NULL
                              AND played_at IS NULL
            WHEN 'finished'  THEN claim_token IS NOT NULL AND replay_key IS NOT NULL
                              AND played_at IS NOT NULL AND engine_digest_played IS NOT NULL
                              AND orion_version IS NOT NULL AND rated_at IS NULL
            WHEN 'rated'     THEN played_at IS NOT NULL AND rated_at IS NOT NULL
                              AND rated_seq IS NOT NULL
            WHEN 'cancelled' THEN withdrawn_reason IS NOT NULL AND closed_at IS NOT NULL
                              AND played_at IS NULL
            WHEN 'failed'    THEN fault_reason IS NOT NULL AND closed_at IS NOT NULL
                              AND played_at IS NULL
        END)
);

CREATE SEQUENCE rating_seq AS bigint;
```

`ladders` is the one array that remains: one or two enum values, written once, tested with
`= ANY`. A table for it would be a table with at most two rows per match; a `class_ladder`
column would hide "and always open" in every reader.

### 3.4 `match_seats` — one row per seat, the facts that are about a seat

```sql
CREATE TABLE match_seats (
    match_id       uuid     NOT NULL REFERENCES matches (id) ON DELETE CASCADE,
    seat           smallint NOT NULL,                 -- 0-based, PROTOCOL.md's seat number

    -- who sits here — pair, at insert
    model_id       uuid     NOT NULL REFERENCES models (id),
    weights_hash   text     NOT NULL,                 -- the loader's identity for the seat
    manifest_hash   text     NOT NULL,
    paired_ratings jsonb,                             -- [{ladder, mu, sigma}] as of the insert

    -- what happened — Kalam, at finish
    rank           smallint,                          -- 1 = best; forfeited seats last
    score          int,
    strikes        smallint,

    -- What this seat's model COST, summed over the turns it was played (decision 46). Each turn's
    -- figure is the loader's `infer_us`, a row's share of its own group's inference -- not the row's
    -- elapsed time, which is latency and includes waiting behind other competitors. Comparable
    -- BETWEEN SEATS OF ONE MATCH, which are rows of one /play call on one replica at one instant;
    -- only indicative across matches. `infer_turns` rather than matches.turns, because a forfeited
    -- seat stopped being played and the match's count would understate its mean.
    infer_us_total bigint,
    infer_us_max   int,
    infer_turns    int,

    PRIMARY KEY (match_id, seat),
    CONSTRAINT match_seats_seat_nonneg   CHECK (seat >= 0),
    CONSTRAINT match_seats_result_whole  CHECK ((rank IS NULL) = (score IS NULL)
                                            AND (rank IS NULL) = (strikes IS NULL)),
    -- Timing is NOT bound to the result, though one statement writes both: it drives no rating, no
    -- rank and no verdict, so binding it would buy no correctness and cost two things -- a row
    -- finished by a Kalam predating the columns would violate the CHECK and halt the wave
    -- mid-deploy, and an unmeasured seat would carry a fake 0 instead of an honest NULL.
    CONSTRAINT match_seats_timing_whole   CHECK ((infer_us_total IS NULL) = (infer_us_max IS NULL)
                                            AND (infer_us_total IS NULL) = (infer_turns IS NULL)),
    CONSTRAINT match_seats_rank_positive CHECK (rank IS NULL OR rank >= 1),
    CONSTRAINT match_seats_strikes_nonneg CHECK (strikes IS NULL OR strikes >= 0),
    CONSTRAINT match_seats_timing_nonneg  CHECK (infer_us_total IS NULL OR
                                                (infer_us_total >= 0 AND infer_us_max >= 0
                                                 AND infer_turns >= 0)),
    -- The worst single turn cannot exceed the sum of every turn: the assertion that catches an
    -- accumulator wired to the wrong field.
    CONSTRAINT match_seats_timing_ordered CHECK (infer_us_total IS NULL
                                                 OR infer_us_max <= infer_us_total)
);
```

| Column group | Why it is where it is |
|---|---|
| `weights_hash`, `manifest_hash` on the seat | Kalam's role cannot read `models`; the hashes are what the seat was paired as, recorded so a replay names the bytes that played it rather than what the version row says today. What the node is *asked* for is the Orion model id, derived from the version id (decision R9) |
| `paired_ratings` as jsonb | keyed by ladder, of which a match has one or two; written once by pair and read by nobody but an auditor. Columns per ladder would be half null |
| what the match did to a seat's ratings | not on the seat: a row per ladder in `rating_events` (§3.5), joined on `(match_id, seat)`, because it is a step in a chain rather than a fact about the seat |
| `ladders` on the match | derived once at insert from the seats' classes (schema §3), so count never re-derives it and a class change on promotion cannot re-label history |
| `trial_version_id` on the match | the one-live-trial rule needs a key on the match; the candidate's seat is a join |
| `seat_count` on the match | written in the same statement as the seats; makes three guards plain — the fault seat's range, "the result names every seat", "one posterior per seat per ladder" |
| `lapses` and `refusals` apart | finding 7c: a memory refusal is the platform's, a lapse is a crash's; only lapses fail a row |
| `fault_*` and `withdrawn_*` apart | two writers, two vocabularies, two grants; the competitor sees one "why" (finding 12.4), assembled by Soma |
| `rated_seq` | finish order is the rating order (principle 5); a sequence records it without trusting clocks |

The cross-table rule — a `finished` match has every seat ranked — is enforced by the finish
statement (§4.6), which writes every seat or nothing, not by a constraint, since a `CHECK` cannot
see another table.

### 3.5 `rating_events` — one row per seat per ladder per counted match

```sql
CREATE TABLE rating_events (
    model_id     uuid        NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    ladder       ladder      NOT NULL,
    seq          int         NOT NULL,       -- 0 is the seed; n is the nth counted match on this ladder
    match_id     uuid        REFERENCES matches (id),         -- null for the seed row
    seat         smallint,
    mu_before    float8,                                       -- null for the seed row
    sigma_before float8,
    mu_after     float8      NOT NULL,
    sigma_after  float8      NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (version_id, ladder, seq),
    FOREIGN KEY (match_id, seat) REFERENCES match_seats (match_id, seat),
    CONSTRAINT rating_events_seq_nonneg CHECK (seq >= 0),
    CONSTRAINT rating_events_seed_shape
        CHECK ((seq = 0) = (match_id IS NULL)
           AND (seq = 0) = (mu_before IS NULL)
           AND (mu_before IS NULL) = (sigma_before IS NULL)
           AND (match_id IS NULL) = (seat IS NULL))
);
```

The rating history, and finding 1's option B′ at the same time. `seq` is the ladder's match count
after the event — `ratings.matches_played` as the fold leaves it — so the primary key is a **chain
constraint**: a match applied twice, or two runs applying different matches from one prior,
collide on `seq` and fail rather than land. The fence in §5.1 stops that earlier; this stops it if
the fence is ever bypassed. Promotion writes `seq = 0` with the seed (§5.3), so a version's history
starts where it started. The `before` values are copied from the `ratings` row as it stood, not
from the plugin's echo, so the chain is the database's truth. `ratings` stays as the current value,
updated in the same statement, and is what the leaderboard reads.

Three reads it serves, each a join: the Version screen's "what this match did to my rating", by
`(match_id, seat)`; a rating-over-time chart, by `(model_id, ladder)` in `seq` order; and the audit
that every event starts where the previous one ended, a self-join on `seq - 1`. If retention ever
archives match rows, this table is what keeps a rating recomputable.

### 3.6 `clocks`

```sql
CREATE TABLE clocks (
    key           text        PRIMARY KEY,
    scheduled_for timestamptz NOT NULL DEFAULT '-infinity',   -- run fence: the occurrence's instant
    attempt       int         NOT NULL DEFAULT 0,             -- run fence: its attempt
    epoch         bigint      NOT NULL DEFAULT 0,             -- roster counter: bumped by every roster writer
    updated_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO clocks (key) VALUES ('count'), ('pair'), ('withdraw'), ('roster');
```

Two flavours in one table, as finding 2 decided. A **run fence** row is claimed by a clock's first
task with its occurrence's `(scheduled_for, attempt)` and checked `FOR SHARE` by every write of
that run. The **roster** row's `epoch` is bumped inside every statement that changes who contests
— promotion, rejection, retirement — and pair reads it at run start and checks it `FOR SHARE` on
every insert. Which of `pair` and `withdraw` claim a run fence is the clocks' own business; the rows cost nothing.

### 3.7 Indexes and the fill factor

```sql
-- the claim: pending rows for one engine, oldest first
CREATE INDEX matches_pending_claim_idx
    ON matches (engine_digest, created_at) WHERE status = 'pending';

-- the wave in flight: read-by-token, renew, finish, and the reap's whole scan (≤ N·K rows)
CREATE INDEX matches_in_flight_idx
    ON matches (claim_token) WHERE status IN ('claimed', 'running');

-- count's scan, in finish order
CREATE INDEX matches_finished_idx
    ON matches (played_at, id) WHERE status = 'finished';

-- one live trial row per candidate — the rule, not a convention
CREATE UNIQUE INDEX matches_one_live_trial_uniq
    ON matches (trial_version_id)
    WHERE trial_version_id IS NOT NULL AND status IN ('pending', 'claimed', 'running', 'finished');

-- every trial a candidate has had, for the verdict and the re-pair cap
CREATE INDEX matches_trial_history_idx
    ON matches (trial_version_id) WHERE trial_version_id IS NOT NULL;

-- a version's matches: GET /matches?version=, withdraw, in-flight per version
CREATE INDEX match_seats_version_idx
    ON match_seats (version_id, match_id);

-- the claim's affinity and its fill: which pending rows share a resident model
CREATE INDEX match_seats_weights_idx
    ON match_seats (weights_hash, match_id);

-- a match's rating events, for the Version screen; the primary key serves the chart and the audit
CREATE INDEX rating_events_match_idx
    ON rating_events (match_id, seat);

ALTER TABLE matches SET (fillfactor = 70);
```

**`lease_expires_at` is deliberately not indexed.** Finding 12.1 (b) asks that a renew be a
heap-only update, and a heap-only update cannot touch an indexed column. The reap therefore scans
the in-flight partial index — at most N replicas × K rows — and filters the expiry in the heap,
which is cheaper than an index on a column rewritten every N turns. The fill factor leaves room
on the page for those rewrites. `match_seats` needs no fill factor: a seat row is written at
insert, at finish and at count, and never on a clock.

### 3.8 The Kalam role

```sql
CREATE ROLE kalam LOGIN;                                    -- password: deployment, from env
GRANT USAGE ON SCHEMA public TO kalam;
GRANT SELECT ON matches, match_seats TO kalam;
GRANT UPDATE (status, claim_token, lease_expires_at, lapses, refusals,
              reason, turns, played_ms, engine_digest_played, orion_version,
              replay_key, played_at, fault_reason, fault_seat, closed_at)
    ON matches TO kalam;
GRANT UPDATE (rank, score, strikes, infer_us_total, infer_us_max, infer_turns)
    ON match_seats TO kalam;
```

Nothing on `models`, `ratings`, `rating_events`, `games`, `users`, `clocks`, and nothing on
`rating_seq`, which count uses as the database owner Soma's connector already is. The claim needs none of them: the
engine digest is a `[vars]` value, the resident hashes come from the loader, and the seats'
hashes are on the seat rows. With `matches_status_shape`, the grant is also what keeps Kalam out
of states that are not its: a valid `cancelled` row needs `withdrawn_reason`, a valid `rated` row
needs `rated_at`, and Kalam can write neither.

### 3.8a `runner_keys` and `runners` — who plays a match

A replica used to be a process holding the `kalam` role, so "which machine played this" was answered
by which container was up. A runner reaches the platform over `/v1/runner/*` from hardware that may
be nowhere near the deployment, and these two tables are the whole of its identity.

| | |
|---|---|
| `runner_keys` | an admin's credential. A **table**, not a column on `users`, so an admin can hold two and retire one without a gap — rotation with no window in which nothing works |
| `runners` | one row per running process, **self-registered** at token exchange on `(key_id, label)`. An admin enrols nothing: "start a runner" is copy the key and run the image, and a second machine on the same key is a second row |
| `live_runners` | the predicate written once — `live_sessions`' argument applied to runners |

**The key is stored as a digest, not as key material.** `key_hash` is sha256 over what the create
route returned exactly once, so reading this table does not let anyone start a runner and a database
dump does not include the fleet. `key_prefix` (`tbr_a1b2c3d4`) is display material: enough to
recognise a key in a list, useless to present. The lookup is still one indexed probe because the
digest is deterministic — a salted password hash would have forced a scan and a verify per row, for
256 bits of machine-generated randomness that does not need stretching.

**`live_runners` is the revocation mechanism, and expiry is not.** A runner's token lasts ten
minutes, but every match statement JOINs this view, so a revoked key, a revoked runner, a deleted
user **or an admin who is no longer one** all end the runner's next call rather than its next
token. It is the rule Soma's admin routes already follow by reading `role` off the live row instead
of off a cookie claim.

The token exchange upserts on `(key_id, label)` and deliberately **does not clear `revoked_at`**: a
revoked machine may keep announcing itself, and it keeps being refused. Resurrection by reconnection
would make revocation advisory.

**`kalam` is granted nothing here**, the way it is granted nothing on `sessions`, and neither was
`jodi` while the clocks had a role of their own. Runner identity is Soma's auth surface: a replica
has no more business reading who may start a runner than reading who may sign in.

`matches.played_by` names the runner, written once at claim. It is not a security control — the
operator is an admin — it is how "which machine is wedged" is answerable at all, and the reap does
not clear it, so a lapsed attempt keeps the attribution of the machine that lost it.

### 3.9 Seeds

`games.active_engine_digest = 'sha256:placeholder'` for `ants`, overwritten by the deploy step;
the four `clocks` rows above; the three baseline users and a `models` row each. The seed is
`devops/compose/bootstrap/seed.sql`'s and is listed here only so the first pair run has a digest to
stamp and a baseline to seat.

### 3.10 The shared functions

A shape several routes return is built once, in the migration, because a shape many routes build is
one that a single route will eventually get wrong on its own — and a ladder that disagrees with
itself by one row is the bug nobody reports and nobody can reproduce.

| Function | What it settles | Called by |
|---|---|---|
| `season_state(seasons)` | the four states, derived from three timestamps rather than stored | `season_json`, the profile, the preflight, both season `why` reads |
| `current_season(game, number?)` | the season a game is read through: the live one, else the latest closed; with `number`, the same selection pinned | the games list and page, the leaderboard, the match listing, both season read-backs |
| `season_json(seasons)` | the season object, with the counts the site prints | six routes |
| `model_phase(model_versions)` | which of the two clocks a version waits on, in the page's words | the version page, the caller's list, `/v1/me`, the preflight |
| `model_ratings(version, settled_sigma)` | a version's ladders, each with rank and field, in the leaderboard's order | the version page, the profile, the caller's list |
| `ladder_field(season, ladder)` | **who is on one ladder**, with `standings.ranked_per_user_max` applied | the leaderboard AND `model_ratings` — see below |
| `match_seat_rows(match)` | a match's seats resolved, with `outcome` | the three match routes, which each shape their own keys from these rows |
| `season_rule_spec()` | **what a season's rules document may say**: one row per key, with its kind and range | `season_rules_ok` |
| `season_rules_ok(jsonb)` | the rules document's shape, refusing an unknown key at both levels | the `seasons.rules` CHECK |
| `season_rules_public(jsonb)` | the rules a season may show the world | `season_json` |
| `season_admits*` ×6 | one predicate per rule: participants, weights, entries, in-flight, versions, class | the writes that must not happen, and the reads that say why |
| `season_cooldown_until(season, model)` | when a model may submit again | the submission `why` read |
| `weight_classes_ok(jsonb)` | what a weight-class table must be: named classes, positive whole caps, strictly ascending | the `seasons.weight_classes` CHECK |
| `notification_category_spec()` | **what a notification may be about**: the six categories, which are locked, which are admin-only, their defaults and `level` vocabulary | the two CHECKs below, `notification_settings_of`, the settings `why` read, the feed's unknown-category refusal |
| `notification_category_ok(text)`, `notification_setting_ok(…)` | a known category; a stored setting the spec allows | the `notifications.category` and `notification_settings` CHECKs |
| `notification_settings_of(user)` | the account's **effective** settings, stored or defaulted, for the categories it can receive | `notification_settings_json`, `notification_wanted`, the settings PATCH |
| `notification_settings_json(user)` | the settings list both settings routes answer with | GET and PATCH `/v1/me/notification-settings` |
| `notification_wanted(user, category, notable)` | **whether one notification reaches one account** | every notification writer, inside its INSERT (§3.11) |

**The rule predicates are the load-bearing set**: each is asked twice per attempt, once by the
write that must not happen and once by the read that says why it did not, and if the two ever
disagreed a competitor would be refused for a reason the response denies. `season_cooldown_until`
is the exception that proves it — the cooldown is a function of `now()`, so the two calls a moment
apart genuinely differ at the boundary, which is why the read returns the INSTANT and never the
boolean.

**`ladder_field()` is the other one worth naming.** Two readers rank against a ladder — the
leaderboard, and a version's own "rank 6 of 47" — and before it they each built the membership set
themselves. That was survivable while a ladder was one row per competitor. It is not now:
`standings.ranked_per_user_max` exists because one active version per ENTRY per season means a
competitor with five models holds five rows, and a cap applied in one reader and not the other
would print a rank the other page cannot justify.

**`match_seat_rows` lost its `strike_limit` parameter.** Telling a forfeit from a defeat needs the
ceiling, and it used to be plumbed from the clocks' `[vars]` through every Soma route that called it —
so Soma's rendering of a forfeit depended on a number in another package's config. It is read off
`matches.strike_ceiling` now: the rule the wave actually played by, and nothing else.

### 3.11 `notifications` and `notification_settings` — what an account is told

**They live in `0002_sessions.sql`, beside `sessions`, and the reason is the grant.** Both files are
the owner's, but 0002 is the file of what belongs to one account and nobody else, and it carries
no `GRANT` at all: `kalam` and `runner_gate` gain nothing, and `scripts/verify/run.sh` asserts it by
role, table and privilege. 0001's grant block is where a reviewer looks for what a match player may
reach, and a table no player may reach does not belong beside it.

| | |
|---|---|
| `notifications` | one row per thing said to one account. The columns are the page's: `subject`, `description` and `link` are rendered as given, `kind` picks an icon family, `tone` a colour, `data` carries the numbers a richer row draws. `model_id`, `version_id`, `match_id` are `ON DELETE SET NULL` — a message outlives what it was about — and `user_id` cascades |
| `notification_settings` | **only what a competitor changed**, one row per touched category. Everything else is the spec's default, so a default changed in the migration reaches everyone who never touched that category |

**The constraints are the vocabulary.** `category` must be in `notification_category_spec()`,
`kind` one of `progress result rank alert season account`, `tone` one of `info ok warn bad`, `data`
an object, and `link` an application path: it starts with `/` and **not** `//`, because
`//host/x` is a path to the site's router and a protocol-relative URL to an address bar. A stored
setting must keep a locked category's `app` on and use its category's own `level` words, or none.

**`dedupe_key` is the idempotence, and `UNIQUE (user_id, dedupe_key)` enforces it.** Every writer is
`INSERT … ON CONFLICT (user_id, dedupe_key) DO NOTHING`, keyed on the event:

| Writer | Where it runs | Key | Category · kind |
|---|---|---|---|
| a version's decided state | `tb-admit-run` `notify` (the item's verdict), `tb-count-run` `notify_promoted` and `notify_rejected` | `version:<id>:<status>` | submissions · progress (`verified`, `active`) or alert (`rejected`) |
| what this admit run expired | `tb-admit-run` `notify_expired`, when `expire` wrote | same | submissions · alert, `TIMED_OUT` |
| a rated match, per seat | `tb-count-run` `notify_result`, after `held` | `result:<match>:<seat>` | matches · result, filtered by `level` |
| a settled rank that moved | `tb-count-run` `notify_rank`, after `notify_result` | `rank:<match>:<version>:<ladder>` | ratings · rank |
| the season this run closed | `tb-withdraw-run` `notify_closed`, when `close` wrote | `season-closed:<season>` | season · season, to everyone who entered |
| a sign-in while another session is live | `soma-auth-github` `notify_signin`, after the session row | `sign-in:<sid>` | account · account |
| a runner on an engine no live season pins | `soma-runner-token` `notify_engine` | `runner-engine:<runner>:<digest>` | admin · alert, to the key's admin |

**Every writer asks `notification_wanted()` inside its INSERT**, so a category that is off writes no
row and the feed needs no second filter. `matches` alone has a `level`: `all` takes every rated
match, `notable` — the default — a first place (a draw at rank 1 included), any strike or a
disqualification, `off` nothing. A baseline has no settings at all, so it is told nothing.

**No writer is inside the statement that decided the thing, and that is deliberate.** Folded into
count's fenced fold as a data-modifying CTE, a result would have been exactly-once — and a CHECK
violation in it would have halted the ladder on every occurrence, for ever. So each writer is its
own `db_write` right after the decision, `continue_on_error`, and **reads the decision off the row**
rather than off `temp_data` (which survives a sweep, so a slot can hold the previous item's value):
the result writer requires `status = 'rated'`, the version writer a decided status, the close writer
the game's latest closed season. The price is a crash window — a run that dies between the decision
and its notify loses that notification — and it can never duplicate one or invent one. The one
change this forced on a deciding statement is admission's expiry, which now stamps **the run's own
token** on the rows it rejects instead of `NULL`, so `notify_expired` finds exactly those rows;
nothing reads a token on a rejected row.

**A rank change is told only on a settled rating**, and only to the seats of the match that moved it.
The rank is `model_ratings()`'s order over `ladder_field()`, computed before the fold (the seats at
their events' `mu_before`/`sigma_before`, everyone else as they stand) and after. A version in
placement moves on nearly every match, and a feed that says so eight times in its first hour is the
noise that makes a competitor turn a category off.

**The routes** are four, all cookie-authed with the `live_sessions` join, all private paths of their
own: `GET /v1/me/notifications` (the feed: `category`, `unread=true`, `since`, keyset `cursor` on
`(created_at, id)`, `limit` clamped 1..100 in the statement, and `unread` counted across every
category), `POST /v1/me/notifications/read` (`ids`, or `all` with an optional `category`; ownership
is the WHERE clause, and an id that is not a uuid is filtered rather than cast), and GET/PATCH
`/v1/me/notification-settings`. PATCH is write-then-diagnose: one upsert refuses whatever the spec
refuses and merges a partial body against the stored row, and `why` names the refusal from the spec
— 400 `unknown_category`, 403 `admin_only`, 409 `category_locked`, 400 `invalid_level` or
`level_not_applicable` — with 400 `invalid_setting` for a value of the wrong type before anything is
written.

**Two indexes serve them:** `(user_id, created_at DESC, id DESC)` for the feed and its cursor, and the
same columns partial on `read_at IS NULL` for the bell's count and the Unread tab.

**Retention is open.** No clock deletes, and none may: `soma-db` sets `operations.delete = false`. A
read notification past some age is the obvious thing to prune, and the writer for it is not chosen.

---

## 4. The match statements, and the routes in front of them

**These eight statements ship from `soma/workflows/soma-runner-*.json`.** They used to live in
`kalam/scripts/gen-kalam.py` and run on a replica's own database connection; a replica now reaches
them over `/v1/runner/*` and holds no credential at all. Nothing about what they *do* changed in the
move — every property below was bought by a finding in [`decisions.md`](decisions.md) §2 and each one
survives byte for byte — but three predicates were added, all about the caller rather than the
match, and §4a is the routes.

**The copies in this file are formatted for reading and are not the authority.** The authority is
the workflow JSON; `scripts/verify/statements.sql` carries a verbatim copy, and
`scripts/verify/run.sh` refuses to run if the two differ. That check exists because this page and
that harness both carried the pre-R7 two-CTE wave claim for months after a one-row claim shipped,
and nothing noticed.

Every statement is conditioned on the claim token, so a stale attempt updates nothing (principle 4).
`$token` is minted **by the gate** with `{"random": ["uuid"]}` — it used to be minted by the runner,
which was safe inside one trust domain and is better central now that a runner is elsewhere: two
runners cannot collide on a token they did not choose.

**The three additions**, and they are the whole of what moving off-site cost the SQL:

| Added | To | Why |
|---|---|---|
| `EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = $runner)` | every statement | revocation and demotion take effect on the next call. Inside the statement, never as a guard task: a JSONLogic guard fails **open** if it is ever wrong, and a JOIN cannot be forgotten |
| the in-flight count against `runners.max_in_flight` | claim | a wedged machine can otherwise sit on rows until their leases lapse. Uncorrelated, so it is an InitPlan evaluated once per claim rather than per candidate row |
| `played_by = $runner` | claim, and read by the rest | which machine played this, and which machine is wedged. Without it the fleet is unobservable |

### 4.1 Reap — `db_write`, its own cron channel

```sql
UPDATE matches
   SET status           = CASE WHEN lapses + 1 >= 3 THEN 'failed' ELSE 'pending' END::match_status,
       lapses           = lapses + 1,
       claim_token      = NULL,
       lease_expires_at = NULL,
       fault_reason     = CASE WHEN lapses + 1 >= 3 THEN 'LEASE_LAPSED' END,
       closed_at        = CASE WHEN lapses + 1 >= 3 THEN now() END
 WHERE status IN ('claimed', 'running')
   AND lease_expires_at < now()
```

Its own statement rather than a CTE inside the claim, because a CTE's writes are invisible to the
claim in the same snapshot: folded in, a reaped row would wait one more poll to be claimed.

**It is no longer every caller's first task.** It was, and that cost was invisible in cluster: at N
runners polling four lanes it is 0.8N reaps a second, each scanning an index whose size is itself
proportional to N — quadratic work for a statement that normally matches nothing. `soma-runner-reap`
runs it once a second in one place instead. That is only *one* place because Soma's Orion is in
**cluster mode**, where a cron singleton is singular across the state database — the exact property
a Kalam replica must never have, which is why a replica has no `[cluster]` block.

`rows_affected` is worth a metric: in cluster it counted crashes. Off-site it counts sleeping
laptops, dropped home links and closed terminals, and it will be routine rather than exceptional.
`played_by` is deliberately **not** cleared, so a lapsed attempt keeps the attribution of the
machine that lost it.

### 4.2 Claim — `db_write`, one row

```sql
WITH pick AS MATERIALIZED (
    SELECT m.id FROM matches m
     WHERE m.status = 'pending' AND m.engine_digest = ($1)::text
       AND m.seat_count <= ($4)::int
       AND EXISTS (SELECT 1 FROM live_runners lr
                    WHERE lr.id = ($5)::uuid
                      AND (SELECT count(*) FROM matches h
                            WHERE h.played_by = ($5)::uuid
                              AND h.status IN ('claimed', 'running')) < lr.max_in_flight)
     ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.created_at, m.id
     LIMIT 1 FOR UPDATE SKIP LOCKED)
UPDATE matches m
   SET status = 'claimed', claim_token = ($2)::uuid,
       lease_expires_at = now() + ($3)::int * interval '1 second',
       played_by = ($5)::uuid
  FROM pick WHERE m.id = pick.id
```

`$1` the engine digest the caller can play · `$2` the token · `$3` lease seconds · `$4` how many
seats its task list has · `$5` the runner.

**This is the only coordinator there is.** `FOR UPDATE SKIP LOCKED` with `LIMIT 1`: a caller takes
the oldest row nobody else holds, trials first. Two callers racing do not queue behind each other —
the second skips the locked row and takes the next — and Postgres is the arbiter whether they are
four cron lanes in one process or forty across ten machines. There is no scheduler, no assignment
table and no registry consulted at pairing time, which is what keeps decision R8 true: **no clock
ever calls a replica.** An assigning coordinator would need a liveness model and a rebalancer for a
machine that vanishes mid-match; pull-plus-lease is self-healing instead, because a runner that has
vanished is indistinguishable from one that is slow and the lease resolves both by the same
statement with nobody having to decide which it was.

`seat_count <= $4` is the refusal that must stay: a seat is a task and the task list is fixed, so a
6-player preset claimed by a 4-lane runner would be a match played short a seat. Refusing to claim
is visible in the queue; playing it short is a match nobody can explain.

The queue partitions on `engine_digest` for free, which is what makes a mixed-engine rollout work.

### 4.3 Read the claimed row — `db_read`

```sql
SELECT json_build_object(
         'id', m.id, 'seed', m.seed, 'preset', m.preset, 'seat_count', m.seat_count,
         'trial_model_id', m.trial_version_id, 'strike_ceiling', m.strike_ceiling,
         'seats', (SELECT json_agg(json_build_object(
                     'm', 0, 'seat', s.seat, 'version_id', s.version_id,
                     'model', ($2)::text || s.version_id::text,
                     'strike_ceiling', m.strike_ceiling,
                     'weights_hash', s.weights_hash,
                     'manifest_hash', s.manifest_hash) ORDER BY s.seat)
                    FROM match_seats s WHERE s.match_id = m.id)) AS row,
       m.engine_digest AS engine_digest, m.lease_expires_at AS lease_expires_at
  FROM matches m
 WHERE m.claim_token = ($1)::uuid AND m.status = 'claimed'
```

Read back only under the token AND `status = 'claimed'`, so a runner that lost its claim between the
two statements plays nothing. One row, so no `row_number()`: the engine's wave still has an `m` and
it is 0 for the whole run.

`model` is **derived** rather than stored — the version id is the model id (R9), so a row and a node
cannot disagree about what to call a model. `weights_hash` and `manifest_hash` are carried for the
replay envelope: the record of what was paired, not what the version row says today.

**`row` is the one object that must not change shape.** It is what a replica reads today, and
proving the HTTP move did not touch how a match is played means comparing it. The two values the
route also needs — the lease it just took and the digest the row demands — ride beside it as their
own columns rather than being folded in.

### 4.4 Start and release

```sql
-- start
UPDATE matches SET status = 'running'
 WHERE id = ($3)::uuid AND claim_token = ($1)::uuid AND status = 'claimed'
   AND played_by = ($2)::uuid
   AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($2)::uuid)

-- release: NOT a fault and NOT a lapse
UPDATE matches
   SET status = CASE WHEN refusals + 1 >= ($3)::int THEN 'failed' ELSE 'pending' END::match_status,
       refusals = refusals + 1, claim_token = NULL, lease_expires_at = NULL,
       fault_reason = CASE WHEN refusals + 1 >= ($3)::int THEN 'MODEL_UNAVAILABLE' END,
       closed_at = CASE WHEN refusals + 1 >= ($3)::int THEN now() END
 WHERE id = ($5)::uuid AND claim_token = ($1)::uuid AND status = 'claimed' AND ($2)::boolean
   AND played_by = ($4)::uuid
   AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($4)::uuid)
```

The barrier between the read and the start is **local to the runner** and costs nothing at either
end, which is why claim and start are two routes rather than one.

Release is what a runner calls when its own roster clock has not caught up with a model the row
seats. The row goes back to the queue with a **refusal** spent rather than a strike, and `refusals`
is counted apart from `lapses` because the two mean different things about the fleet. At the ceiling
the row fails as `MODEL_UNAVAILABLE`, which is what stops a runner that is permanently behind
passing one row round the fleet for ever.

> **A ninth statement is gone.** `K_FAIL` failed a whole wave by weights hash, needed because the
> loader answered about `(weights_hash, manifest_hash)` pairs and a workflow could not join that
> back to rows. The wave went with R7 and the loader went with the 1.8.1 rebuild, and a fault on a
> seat is reported through the finish now. `scripts/verify/scenario.sql` sets that state with a
> plain `UPDATE`, marked as setup rather than as a statement under test.

### 4.5 Renew — every N turns

```sql
UPDATE matches SET lease_expires_at = now() + ($2)::int * interval '1 second'
 WHERE id = ($4)::uuid AND claim_token = ($1)::uuid AND status = 'running'
   AND played_by = ($3)::uuid
   AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($3)::uuid)
```

**The lease has always been the database's clock**, and that is what makes moving the caller onto a
machine whose clock nobody controls free: the runner never sends a timestamp. No indexed column
changes, so the update stays heap-only — the reason `matches` carries `fillfactor = 70` and the
reason `lease_expires_at` is deliberately unindexed (§3.7).

**What changed is the answer, not the statement.** In cluster, `halt_unless(wrote(renewed))` was
right: a renew that wrote nothing meant the claim was gone. Over a WAN a renew that *errored* means
almost nothing, and the two must be told apart — so the route answers `200 {applied, lease_expires_at}`
and lets the runner decide. `applied: false` is the claim genuinely gone: halt. A transport failure
is a retry, and the margin for retrying is the ratio the two numbers must keep:

> `renew_every_n_turns × turn_ms × 3 < lease_seconds`

The response returns the new `lease_expires_at` because the runner now needs its own runway, which
in cluster it never had to know.

### 4.6 Finish — one statement, as the match ends

```sql
WITH m AS (
    UPDATE matches
       SET status = 'finished', reason = ($4)::text, turns = ($5)::int,
           played_ms = GREATEST(0, (EXTRACT(EPOCH FROM (now() - ($6)::timestamptz)) * 1000)::int),
           engine_digest_played = ($7)::text, orion_version = ($8)::text,
           replay_key = ($9)::text, played_at = now(), lease_expires_at = NULL
     WHERE id = ($2)::uuid AND claim_token = ($1)::uuid AND status = 'running'
       AND played_by = ($10)::uuid
       AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($10)::uuid)
       AND (SELECT count(DISTINCT v.seat) FROM jsonb_to_recordset(($3)::jsonb) AS v (seat smallint)
             WHERE v.seat BETWEEN 0 AND seat_count - 1) = seat_count
 RETURNING id)
UPDATE match_seats s
   SET rank = v.rank, score = v.score, strikes = v.strikes,
       infer_us_total = v.infer_us_total, infer_us_max = v.infer_us_max,
       infer_turns = v.infer_turns
  FROM m, jsonb_to_recordset(($3)::jsonb)
       AS v (seat smallint, rank smallint, score int, strikes smallint,
             infer_us_total bigint, infer_us_max int, infer_turns int)
 WHERE s.match_id = m.id AND s.seat = v.seat
```

`$1` token · `$2` match · `$3` the result, one element per seat · `$4` the engine's end reason ·
`$5`, `$6` turns and duration · `$7`, `$8` the digests that played it · `$9` the replay key ·
`$10` the runner.

One statement: the row and all its seats move together or neither does. The seat-count check refuses
a result naming fewer seats than the match has — that row stays running and the reap returns it to
the queue, which is recoverable, where a half-written match is not.

The replay `PUT` precedes it under a key naming the token, so a stale attempt's blob is an orphan
under its own key rather than a replacement (finding 7d). `claim_token` stays on the finished row:
it is the attempt that counted — and §4a.2 is why that matters more than it used to.

### 4.7 The roster — `db_read`, every tick

The statement is unchanged and is quoted in full in `workflows/soma-runner-roster.json`. Two
properties are worth repeating here because they are easy to lose in a refactor:

- **`verified` as well as `active`.** A verified version's trial is a real match, paired before
  promotion, so a runner that waited for `active` could never play the trial that produces it.
- **The manifest is rebuilt field by field, at the centre.** A competitor's manifest can name a
  `reference` — the one field that could point outside their own version — and rebuilding the
  document key by key leaves it nowhere to survive. `name` becomes the platform's model id for the
  same reason: Orion takes a model's id from the manifest and a competitor's name is not the
  platform's (R9). **This rebuild must never move to the edge.** It is the reason a malformed
  manifest cannot reach a node's registration, and it stops being true the moment a runner builds
  the document itself.

---

## 4a. The routes in front of them

One channel and one workflow per route, Soma's house shape: `sync`, `rest`, `response.mode: shaped`,
a flat task list ending in `data.body` + `data._orion.response`.

| Route | Statements | Answers |
|---|---|---|
| `POST /v1/runner/token` | key lookup, `runners` upsert, `jwt_sign` | `{token, expires_in, runner_id}` |
| `POST /v1/runner/claim` | 4.2, 4.3 | `200` the row + the execution contract, or `200 {"idle": true}` |
| `POST /v1/runner/matches/{id}/start` | 4.4 | `{started}` |
| `POST /v1/runner/matches/{id}/release` | 4.4 | `{released, refusals, failed}` |
| `POST /v1/runner/matches/{id}/renew` | 4.5 | `{applied, lease_expires_at}` |
| `POST /v1/runner/matches/{id}/replay-url` | — (`storage_presign` PUT) | `{url, key, endpoint}` |
| `POST /v1/runner/matches/{id}/finish` | 4.6, then a read-back | `{applied, state}` |
| `GET  /v1/runner/roster` | 4.7 | the same `body` object it built before |
| — *(cron, not a route)* | 4.1 | `soma-runner-reap`, once a second |

Five more are admin-facing and session-authed, over `runner_keys` and `runners`:
`POST`/`GET /v1/runner-keys`, `DELETE /v1/runner-keys/{id}`, `GET /v1/runners`,
`DELETE /v1/runners/{id}`.

### 4a.1 The claim's idle answer, and the execution contract

An idle runner polling four lanes every five seconds is 0.8 requests a second **independent of how
busy the ladder is**, so the idle answer is the one that has to be cheap: one indexed probe and a
body of `{"idle": true}`. It is also the first thing that will strain, and it strains on a number
that has nothing to do with queue depth.

> **It was a `204`, and running it changed that.** A 204 carries no body, and every caller of this
> route parses JSON because every other answer is JSON — so the idle case failed the parse, `EOF
> while parsing a value at line 1 column 0`, once per poll per lane. The runner survived it and idled
> correctly, and logged an error 0.8 times a second for **the common case**: a healthy fleet that
> reads as a broken one, which is the failure shape this platform is most careful about everywhere
> else. Fourteen bytes was the whole saving. `constants.no_content` stays for `soma-admin-check`,
> where a 204 *is* the answer and nginx is the only client.

The 200 carries three objects — `match` (§4.3's `row`), `claim`, and **`contract`**:

```json
{ "turn_ms": 1000, "max_turns": 1000, "model_prefix": "tb.v",
  "engine_digest": "sha256:…", "replay_prefix": "replays",
  "renew_every_n_turns": 30, "lease_seconds": 300, "refusal_ceiling": 3 }
```

`strike_ceiling` already worked this way — decision 54 put it on the row so a trial is judged by the
rule it was played under. This extends the same argument to everything else a match is played under.
These were `[vars]` on each replica, asserted equal across repositories by
web's `scripts/check/configs.sh`, **which cannot read a machine on somebody's desk**: a value that
must be equal in two places is instead sent from the one place that owns it. `engine_digest` comes
off the claimed row rather than from a var, so a mixed-engine rollout stays correct by construction.

**Three of the eight now come from the season (N18), and the read is in §4.3's statement.** A season
owns the terms a model competes under, so `turn_ms`, `max_turns` and `refusal_ceiling` are read

```sql
coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean
              THEN (se.rules -> 'execution' ->> 'turn_ms')::int END,
         (g.manifest -> 'limits' ->> 'turn_ms')::int,
         ($6)::int)
```

from **the row's own season**, the shape admission already uses for `adapter_ops_max`. A season that
declares nothing plays by the cartridge's published limits — which is where `turn_ms` and
`max_turns` have always really lived, `games.manifest` being written from `cartridge.json` by the
loader. `refusal_ceiling` has no manifest key, because the cartridge has no opinion about how often
a *node* may refuse a row, so it falls straight through to the var.

**Nothing is pinned onto the match row for this**, and it does not need to be: `seasons.rules` is
immutable once `submissions_open_at` passes, the same property that lets count read a season's
rating constants at fold time. A queued match cannot have its terms changed under it.

**`enabled` is honoured rather than ignored.** Value-supplying blocks elsewhere (`pairing`,
`closure`) coalesce their keys without checking it, and that is a footgun this block does not copy:
a rule that applies when its author turned it off is the failure `season_rules_ok()` was written to
prevent — its own comment is about a season storing `enabld` cleanly and then admitting the world.

**`renew_every_n_turns` is DERIVED, not sent.** It is the deployment's target clamped by the season:

```sql
GREATEST(1, LEAST(($4)::int, (($5)::int * 1000) / ((m.seat_count + 1) * e.turn_ms)))
```

Without that, a season raising `turn_ms` leaves the lease expiring before the renew fires — 30 turns
at 5000 ms is 450 s against a 300 s lease, **on every match**, and it reads as a wedged runner. A
range check on `turn_ms` cannot close it, because the safe ceiling depends on `lease_seconds`, which
lives in a different file. Clamping makes `renew_every_n_turns × turn_ms × (seat_count + 1) ≤ lease_seconds` true
by arithmetic. The multiplier is the row's `seat_count + 1` — every seat's deadline and the step —
because a turn of an eight-seat map can cost nine deadlines where a two-seat one costs three. At the
defaults it is `min(30, 100) = 30` on two seats and `min(30, 33) = 30` on eight; at `turn_ms = 5000`
it is 20 on two seats and 6 on eight.

Three values cannot ride the row because they are Orion *instance* config rather than workflow data:
`engine.ops_budget`, `orion_version` and `max_timeout_ms`. A node cannot be told its own ops budget.
The runner reports them at token exchange and the gate refuses one whose budget is not the season's —
a misconfiguration check, which is worth exactly that, because with trusted operators
misconfiguration is what actually happens.

### 4a.2 Finish must be idempotent, because now it can be delivered twice

In cluster this call could not be delivered twice. Over a WAN it can, and §4.6 alone cannot tell "I
already did this" from "my token is stale" — both are `rows_affected = 0`. A runner that finished,
lost the response and retried would report a fault on a match it had just completed correctly.

So the route writes and then **reads the row back under the same token**:

| `rows_affected` | row now reads | answer |
|---|---|---|
| 1 | finished | `200 {applied: true, state: "finished"}` |
| 0 | `finished` **and** `claim_token` matches | `200 {applied: false, state: "finished"}` — duplicate delivery, a success |
| 0 | anything else | `409 {applied: false, state: …}` — the claim really is gone |

This is the "write, then diagnose" shape the package already uses for every refusal, applied to the
one statement where the ambiguity is new. A route that conflates the two fails a healthy runner
mid-match.

### 4a.3 What the gate holds so a runner does not

- **The database.** The runner has no connection string. The routes run over `soma-db`, and
  `0001_init.sql`'s grant block records what that costs: the column-limited `kalam` role is no
  longer what stops a runner statement writing a rating. Review is.
- **The replay bucket's write key.** `soma-runner-blobs` is `presign_put` only, and the gate signs
  for the key **it** computes from the claim it issued — `replay_prefix/{match}/{claim_token}.json`
  — so a runner cannot write under another attempt's key even by accident. `soma-blobs` stays
  `presign_get` only: a read connector that can also write is one nobody can reason about.
- **Nothing on the bulk path.** The replay PUTs straight to the object store. Putting it through a
  REST workflow would make one node the throughput bottleneck of the whole ladder for no gain a
  presigned per-attempt URL does not already give.

---

## 5. Count's statements

Parameters `$1`, `$2` are always `metadata.trigger.scheduled_for` and `metadata.trigger.attempt`.

### 5.1 Claim the run fence — first task

```sql
UPDATE clocks
   SET scheduled_for = ($1)::timestamptz, attempt = ($2)::int, updated_at = now()
 WHERE key = 'count'
   AND (scheduled_for, attempt) < (($1)::timestamptz, ($2)::int)
```

Zero rows: a newer occurrence has claimed; halt without reading anything. A retry of an older
occurrence is fenced out here, which is right because every run scans the same unmarked set.

### 5.2 The fold — one statement per match, in finish order

The batch read lists ids only — `SELECT id FROM matches WHERE status = 'finished' ORDER BY
played_at, id LIMIT ($1)::int` — and the priors are read per match, immediately before the plugin
call, because a model in two consecutive matches has a different prior for the second:

```sql
SELECT json_build_object(
         'id', m.id, 'trial_version_id', m.trial_version_id, 'ladders', m.ladders,
         'seat_count', m.seat_count,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.version_id, 'rank', s.rank, 'strikes', s.strikes,
                      'ratings', (SELECT json_agg(json_build_object(
                                            'ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                                          ORDER BY r.ladder)
                                    FROM ratings r
                                   WHERE r.version_id = s.version_id AND r.ladder = ANY (m.ladders)))
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row
  FROM matches m
 WHERE m.id = ($1)::uuid AND m.status = 'finished'
```

Then, with `$4` the plugin's output — the posteriors only, one element per seat per ladder:

```sql
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
       AND m.trial_version_id IS NULL                                     -- trials take §5.3, never this
       AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders)
 RETURNING m.id
), post AS (
    SELECT p.*
      FROM mark,
           jsonb_to_recordset(($4)::jsonb)
             AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8)
), applied AS (
    UPDATE ratings r
       SET mu = post.mu, sigma = post.sigma,
           matches_played = r.matches_played + 1, updated_at = now()
      FROM post, ratings old                                             -- the row as it stood
     WHERE r.version_id = post.version_id AND r.ladder = post.ladder::ladder
       AND old.model_id = r.version_id AND old.ladder = r.ladder
 RETURNING r.version_id, r.ladder, r.matches_played AS seq, post.seat,
           old.mu AS mu_before, old.sigma AS sigma_before, r.mu AS mu_after, r.sigma AS sigma_after
)
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat,
                           mu_before, sigma_before, mu_after, sigma_after)
SELECT a.model_id, a.ladder, a.seq, mark.id, a.seat,
       a.mu_before, a.sigma_before, a.mu_after, a.sigma_after
  FROM applied a, mark
```

`$4` is `[{"seat": 0, "model_id": "…", "ladder": "open", "mu": 27.1, "sigma": 6.9}, …]`. The
plugin returns what the ratings become; the database records what they were, from the `ratings`
row joined as it stood before the update, so an event's `before` is the chain's truth rather than
the plugin's echo. `rows_affected` is the events inserted, seats × ladders — four for a same-class
2P match, two for a cross-class one. Zero means the fence is gone or the row was already marked:
halt. The length guard on the mark matters because a data-modifying CTE runs to completion
whether or not the main statement uses its output: without it, a plugin reply with the wrong
number of entries would mark the row `rated` and apply nothing, and `rows_affected` would report
zero as if the fence had been lost. With it, the mark lands only when exactly one posterior per
seat per ladder arrived; a count between zero and the expected number means a rating row was
missing, which count alerts on rather than halts. A run applying the same match twice from one
prior would also collide on `rating_events`' primary key — the chain constraint doing the fence's
job a second time. The `FOR SHARE` on the fence row is what orders this check against a newer
run's claim in §5.1, which takes the row lock: one of the two waits, and whichever runs second
sees the other's fence (finding 1).

### 5.3 The three verdicts on a trial

Count decides a candidate whose trial is terminal and whose `models` row is still `verified`:

```sql
SELECT json_build_object('model_id', c.id, 'owner_id', c.owner_id, 'game_id', c.game_id,
         'trials', (SELECT count(*) FROM matches t WHERE t.trial_version_id = c.id),
         'last', (SELECT json_build_object('id', t.id, 'status', t.status,
                          'fault_seat', t.fault_seat, 'fault_reason', t.fault_reason,
                          'candidate_seat', cs.seat, 'candidate_rank', cs.rank,
                          'candidate_strikes', cs.strikes)
                    FROM matches t
                    JOIN match_seats cs ON cs.match_id = t.id AND cs.version_id = c.id
                   WHERE t.trial_version_id = c.id
                   ORDER BY t.created_at DESC LIMIT 1)) AS row
  FROM model_versions c
 WHERE c.status = 'verified'
   AND EXISTS (SELECT 1 FROM matches t WHERE t.trial_version_id = c.id
                AND t.status IN ('finished', 'failed', 'cancelled'))
```

The rules are finding 6b's; the words are the clocks'. Three outcomes, three statements:

**Pass** — `finished`, the candidate's seat not forfeited. One statement: mark the trial, bump the
roster, supersede the predecessor, activate the candidate, seed its two rating rows and write
their seed events.

```sql
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), pred AS (
    UPDATE model_versions p SET status = 'superseded'
      FROM bump, models cand
     WHERE cand.id = ($4)::uuid
       AND p.owner_id = cand.owner_id AND p.game_id = cand.game_id AND p.status = 'active'
 RETURNING p.id
), cand AS (
    UPDATE model_versions c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
       AND (SELECT count(*) FROM pred) >= 0            -- runs pred to completion first
 RETURNING c.id, c.weight_class
), seeded AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, ($5)::float8),                      -- the prior when no predecessor
           coalesce(seed.sigma, ($6)::float8),
           prev.mu,                                               -- null when no predecessor
           seed.sigma                                             -- null when no predecessor
      FROM cand
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.model_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          -- the inflated sigma, capped at the prior; null when there is nothing to inflate.
          -- Spelled as a CASE because least() ignores nulls and would turn "no predecessor" into the prior.
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * ($7)::float8, ($6)::float8) END AS sigma
      ) seed
 RETURNING model_id, ladder, mu, sigma
)
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT model_id, ladder, 0, mu, sigma FROM seeded                  -- the history starts at the seed
```

`$3` the trial row · `$4` the candidate · `$5`, `$6` the prior `mu`, `sigma` · `$7` the sigma
inflation — provisional from the clocks' config, final from 06. `rows_affected` is 2, the two `seq = 0`
events. The aggregate over
`pred` in `cand`'s predicate orders the predecessor's demotion before the candidate's activation.
It is no longer what makes the statement correct: the one-active rule is an exclusion constraint
deferred to commit (§3.2), so either order commits, and §9 proves the reverse order does. It stays
because it costs nothing and says what the statement means.
A class change seeds the class ladder from the prior, as schema §3 says it should.

**Reject** — the candidate forfeited, or the row `failed` with `fault_seat` its seat. Mark the
trial if it finished, bump the roster (a rejection is a roster write — finding 2 E), reject:

```sql
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM fence
     WHERE c.key = 'roster' AND (SELECT count(*) FROM mark) >= 0
 RETURNING c.epoch
)
UPDATE model_versions md
   SET status = 'rejected', reject_reason = ($5)::text
  FROM bump
 WHERE md.id = ($4)::uuid AND md.status = 'verified'
```

**Re-pair** — `failed` unattributed, or `cancelled`. Count writes nothing: the row is already
terminal and not live, so pair's next run inserts a fresh trial (§6.2) because the candidate is
verified with no live trial row. The cap is count's: when `trials` in the read above reaches
the configured number without a pass, the reject statement runs with the unplayable reason.

### 5.4 Promotion's second statement — withdraw the predecessor's queue

```sql
UPDATE matches m
   SET status = 'cancelled', withdrawn_reason = 'SUPERSEDED',
       successor_version_id = ($2)::uuid, closed_at = now()
 WHERE m.status = 'pending'
   AND EXISTS (SELECT 1 FROM match_seats s WHERE s.match_id = m.id AND s.version_id = ($1)::uuid)
```

`$1` the predecessor · `$2` the candidate. Unfenced on purpose: a superseded version stays
superseded, so the statement is idempotent and a stale run doing it is harmless. Its fresh
snapshot sees every pair insert that committed before the bump (finding 2). A crash between §5.3
and this is what §7.1 sweeps. A trial row whose baseline opponent was `$1` is cancelled too, and
count re-pairs it.

---

## 6. Pair's statements

### 6.1 The roster read — first task

```sql
SELECT epoch FROM clocks WHERE key = 'roster'
```

Held in `data` for the run. The demand view and the depth read are pair's.

### 6.2 The fenced insert — one per match, the match and its seats in one statement

```sql
WITH seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, md.id AS model_id, md.weights_hash, md.manifest_hash, md.weight_class
      FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (model_id, ord)
      JOIN model_versions md ON md.id = seat.model_id
      JOIN games g ON g.id = md.game_id AND g.slug = ($2)::text
     WHERE md.status = 'active'                                          -- contesting, by inclusion
        OR (md.status = 'verified' AND md.id = ($6)::uuid)                -- the candidate of a trial
), m AS (
    INSERT INTO matches (game_id, engine_digest, seed, preset, seat_count, ladders,
                         trial_version_id, pairing_id)
    SELECT g.id, g.active_engine_digest, ($3)::bigint, ($4)::text, cardinality(($5)::uuid[]),
           CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[]          -- a trial feeds no ladder
                WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1
                     THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[]
                ELSE ARRAY['open']::ladder[]                              -- mixed classes: open only
           END,
           ($6)::uuid, ($7)::uuid
      FROM games g
      JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence
        ON true
     WHERE g.slug = ($2)::text
       AND g.active_engine_digest IS NOT NULL
       AND (SELECT count(*) FROM seated) = cardinality(($5)::uuid[])    -- every seat found, contesting, verified
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, paired_ratings)
SELECT m.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash,
       (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                         ORDER BY r.ladder)
          FROM ratings r WHERE r.version_id = s.version_id)
  FROM m, seated s
```

`$1` the epoch read at run start · `$2` game slug · `$3` seed · `$4` preset · `$5` the seats'
model ids in seat order · `$6` the candidate, or null · `$7` pairing id. The plugin chooses ids,
seed and preset; the statement derives the hashes, the ladders, the contesting check and the
rating snapshot from `models` and `ratings`, so pair carries no copy of the roster rules and the
snapshot is what the database held at the instant of insert. `rows_affected` is the seat count;
zero means the roster moved under the run, a seat left, or the candidate is not `verified` — either way
halt, and the next run re-reads. A second live trial for one candidate is refused by the unique
index, which is a bug in pair's read, not a race, and the run halts loudly.

---

## 7. Withdraw's sweep, and what Soma's queries need

### 7.1 The sweep — every minute or so, idempotent, unfenced

```sql
UPDATE matches m
   SET status = 'cancelled', closed_at = now(),
       withdrawn_reason =
           CASE WHEN m.engine_digest <> g.active_engine_digest THEN 'ENGINE_RETIRED'
                ELSE (SELECT CASE md.status WHEN 'superseded' THEN 'SUPERSEDED'
                                            WHEN 'rejected'   THEN 'REJECTED'
                                            ELSE 'SEAT_LEFT' END
                        FROM match_seats s
                        JOIN model_versions md ON md.id = s.version_id
                       WHERE s.match_id = m.id
                         AND NOT (md.status = 'active'
                               OR (md.status = 'verified' AND md.id = m.trial_version_id))
                       ORDER BY s.seat LIMIT 1)
           END,
       successor_version_id =
           (SELECT succ.id
              FROM match_seats s
              JOIN model_versions gone ON gone.id = s.version_id AND gone.status = 'superseded'
              JOIN model_versions succ ON succ.owner_id = gone.owner_id AND succ.game_id = gone.game_id
                              AND succ.status = 'active'
             WHERE s.match_id = m.id
             ORDER BY s.seat LIMIT 1)
  FROM games g
 WHERE g.id = m.game_id AND m.status = 'pending'
   AND (m.engine_digest <> g.active_engine_digest          -- <> not IS DISTINCT FROM: a null digest pauses, never cancels
     OR EXISTS (SELECT 1 FROM match_seats s
                  JOIN model_versions md ON md.id = s.version_id
                 WHERE s.match_id = m.id
                   AND NOT (md.status = 'active'
                         OR (md.status = 'verified' AND md.id = m.trial_version_id))))
```

"Contesting" is written by inclusion — `active`, or `verified` for the candidate seat of a trial —
so `retired` in P7 fails closed without a change here. The reason words are proposals for layer
02; the shape is fixed.

### 7.2 Soma's existing queries

`matches` now holds queued rows and its seats live in a second table, so two of Soma's workflows
change and nothing else does — both get simpler:

- `soma-matches-list` becomes a join: `FROM match_seats s JOIN matches mt ON mt.id = s.match_id
  WHERE s.version_id = $1 AND mt.status IN ('finished', 'rated') ORDER BY mt.played_at DESC`, on
  `match_seats_version_idx`. Queued rows on request, for the owner, per finding 12.4. The GIN
  containment scan and its sort are gone.
- `soma-matches-get` reads its players from `match_seats` ordered by seat and each seat's rating
  change from `rating_events` on `(match_id, seat)`, and gains the additive fields: `status`,
  `withdrawn_reason`, `successor_version_id`, `strikes`, the rating change, the digests.

"In flight per version" — what decision 1's policy will count — is `SELECT count(*) FROM
match_seats s JOIN matches m ON m.id = s.match_id WHERE s.version_id = $1 AND m.status IN
('pending', 'claimed', 'running')`. Layer 01 needs no column for it.

---

## 8. Decisions taken here

Decisions **2** (seat shape), **3** (seed columns), **7** (the lapse ceiling), **18** (one preset
per wave), **21** (the `verified` status) and **22** (the `rating_events` table) were taken here,
along with the unnumbered calls the statements forced — promotion as one statement, the rating
mark, the reap as its own statement, `models.manifest` as exact text, and the schema being initial
rather than a migration chain.

Each is recorded with its reasoning and the cost of flipping it in
[decisions.md](decisions.md) §3,
under *The match table*.

## 9. What has been verified, and what the Orion spikes must still prove

### 9.1 Verified — 7 September 2026, Postgres 16 in the local compose stack

[`scripts/verify/run.sh`](../scripts/verify/run.sh) reproduces it: a scratch database beside `soma`, `0001`
and `0002` applied — §3 is now the initial migration itself, so there is no delta file — then every
statement in §4–§7 `PREPARE`d with the parameter types written here, then the walk in
[`scripts/verify/scenario.sql`](../scripts/verify/scenario.sql). What held:

- **The schema** applies over `0001` and `0002` on a fresh database — the `verified` value added
  to `model_status`, the one-in-flight index replaced — and every statement parses and plans.
- **The walk.** Pair inserts a trial (`ladders = '{}'`) and a same-class row (`{nano, open}`), two
  seat rows each with the rating snapshot on them; a second live trial is refused by
  `matches_one_live_trial_uniq`; a stale epoch inserts nothing. The claim takes the trial first
  and fills with the same-preset row sharing its baseline, and a second replica gets only the
  other-preset row. Start, renew and finish answer the counts §4 states; a foreign token renews
  nothing; a result that names one seat twice writes nothing and leaves the row `running`; a
  second finish is a no-op. A lapsed lease is reaped to `pending` with `lapses = 1`
  and its token cleared. The fence claim admits a newer occurrence and a retry, and refuses an
  older one. The fold applies four rating rows under the live fence and writes four rating events whose
  `before` values are the priors, none under a stale one, none twice, and never touches a trial
  row; a hand-inserted duplicate `seq` is refused by the chain key, and the chain audit finds no
  break. The
  verdict read finds the candidate with its seat; the pass statement flips the versions and
  seeds two rating rows from the predecessor's with sigma doubled and writes their two `seq = 0`
  events, bumps the roster to 1 and marks the trial — and `models_one_active_uniq` did not fire, so the aggregate dependency
  ordered `pred` before `cand`. A second pass inserts nothing. Promotion's withdraw cancels the
  predecessor's queued row naming the successor; pair with the pre-promotion epoch is fenced out
  and with the new one is not. The sweep cancels a row on a retired digest and does nothing when
  the digest is null. A trial failed with `fault_seat = 0` is read and rejected, bumping the
  roster to 2. A memory refusal returns a row to `pending` with `refusals = 1` and no lapse, and
  the ceiling fails it `UNLOADABLE`. A version's history is one join on `match_seats_version_idx`.
- **The adapter copy** is accepted when its text hashes to `manifest_hash` and refused by
  `model_versions_manifest_matches_hash` when one byte differs.
- **Promotion in the reverse order** — a variant of §5.3's statement that activates the candidate
  before demoting the predecessor — commits under the deferred exclusion constraint, which it could
  not under a partial unique index.
- **The Kalam role** can read both tables, cannot write `withdrawn_reason` or a seat's `model_id`
  (permission denied), cannot set `cancelled` without a reason (`matches_status_shape` refuses),
  cannot set `rated` (no grant on `rated_at`), cannot rank a seat without its score and strikes
  (`match_seats_result_whole` refuses), and cannot read `models` or read or write
  `rating_events`.
- **The two fence races**, with two sessions: a newer occurrence's claim held uncommitted while a
  stale fold ran — the fold blocked behind the row lock for the holder's remaining two seconds,
  then wrote nothing, the row still `finished`; and a live fold held `FOR SHARE` while a newer
  claim ran — the claim blocked the same two seconds, then succeeded, with the fold's write
  standing. Afterwards the promoted version's history reads `seq = 0` from the seed and `seq = 1`
  from that fold on both ladders, and the chain audit finds no break. Both orders are correct, as
  finding 1 argues.

### 9.2 Not verified — the Orion spikes's part

1. **Orion's binds**, on the running node: a leading `WITH` through `db_write`; `rows_affected`
   of a CTE statement counting the main statement; `uuid[]` and `text[]` parameters from a
   `map`-built array; a `jsonb` parameter from the plugin's output;
   `metadata.trigger.scheduled_for` cast to `timestamptz`. Each is read from the source in §2 and
   none has been run through a task.
2. **The fence on a cron channel**: §5.1 from `metadata.trigger`, and a manual trigger
   forced to overlap a running occurrence with `forbid` off, halting on zero rows. The Postgres
   half is 9.1; the Orion half — the metadata, the halt, what a dead node costs under the channel
   timeout — is the spike's.
3. **The claim under load.** Several pollers on §4.2 against a queue of thousands:
   whether the two `EXISTS` on `match_seats` in the ordering and the fill cost more than the
   partial index saves, whether the `ORDER BY` needs splitting into a trials query and a
   fallback, and whether the reap should fold into the claim.

---

## 10. Open questions

Beyond the §8 decisions, three things the review did not reach:

1. **`reason` on a `finished` row** stays the engine's free text (schema §5). Kalam must say
   whether a forfeit overwrites it or is inferred from the seat's `strikes` — the rows carry both.
2. **`paired_ratings`' content** is derived here from `ratings` at insert; whether the pairing
   plugin wants more recorded — the demand it answered, the fraction it drew — is the clocks'.
3. **Trial rows and the count fence.** A `failed` or `cancelled` trial is never marked; count
   decides it from `models.status = 'verified'` and re-decides idempotently. That is simpler than
   a mark but means the verdict read in §5.3 scans `verified` models every run — cheap under
   one-in-flight, and worth stating.
