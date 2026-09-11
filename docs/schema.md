# The schema

The contract all three Orion packages build against: a match row, its seat rows and its rating
events, the `clocks` table and its two fences, and every statement Jodi and Kalam run against them,
written out.

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
[devops/docs/architecture.md](https://github.com/Tiny-Brains/devops/blob/main/docs/architecture.md)
§3. The decisions this schema took — 2, 3, 7, 18, 21, 22 — are in
[devops/docs/decisions.md](https://github.com/Tiny-Brains/devops/blob/main/docs/decisions.md) §3.

## 1. What this page fixes

| Settled here | Left to |
|---|---|
| `match_status` and the walk between its values | — |
| every column of `matches`, `match_seats` and `rating_events`, typed, with its one writer | — |
| `models.adapter`, `models.evaluator_digest`, the `verified` status | 04 the dialect; 08 what fills them |
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
  ▲ ▲ │     Kalam              Kalam            Kalam                  Jodi
  │ │ └────── a seat left, or the engine retired ──▶ cancelled        Jodi
  │ └──────── lease lapsed; the next claim reaps ◀──┴────┘            Kalam
  └────────── the loader refused residency; no lapse counted          Kalam
                             a third lapse, the refusal ceiling,
                             or a fault Kalam can name ──▶ failed     Kalam
```

`finished`, `rated`, `cancelled` and `failed` are permanent. Nothing here is deleted.

### 3.2 `games`, `models` and `model_versions`

**An entry and a version are two tables** (decision 51). `models` is the ENTRY — a competitor's
named lineage, keyed by the GitHub repository it publishes from — and `model_versions` is one
submission of it. Everything a rating, a seat or a match points at is a VERSION; a rename, a
retirement and a quota are about the ENTRY.

Before the split there was one table, and "the entry" was spelled `(owner_id, game_id)` inside
seven statements. That is exactly why a competitor could hold only one: the identity had nowhere
to live but a pair of foreign keys, so every rule that should have been per lineage was per person.

```sql
CREATE TABLE models (              -- the entry
    id, owner_id, game_id,
    name,                          -- the competitor's own word for it, theirs to edit
    repo,                          -- CANONICAL owner/name, CHECK (repo = repo_path(repo))
    created_at,
    retired_at                     -- "no more releases here"; not a delete, and reversible
);
CREATE UNIQUE INDEX models_owner_game_repo_uniq ON models (owner_id, game_id, lower(repo));
CREATE UNIQUE INDEX models_owner_game_name_uniq ON models (owner_id, game_id, lower(name));
```

**The repository uniqueness index is keyed on the OWNER and deliberately not globally on
`(game_id, lower(repo))`.** The cross-competitor half of "one entry per repository" follows from
`repo_owned()` instead — a repository's first path segment must be the competitor's own GitHub
login, which `users.handle` IS, because `soma-auth-github`'s upsert writes `gh.login` into it on
every sign-in. Stating it as a global index as well would be a permanent claim on a namespace that
is not ours: GitHub logins are recyclable and repositories transferable, so a global index would
refuse a competitor the repository they now own because a stranger's retired entry named it two
years ago. It is also what lets the three baselines — three users, one shared repository — exist.

It is **not** partial on `retired_at`, because retiring must not become a way to restart a version
series or re-enter a release tag.

`model_versions` carries what `models` used to, plus `model_id`, plus a denormalised `game_id` that
is **proved** rather than trusted: with `FOREIGN KEY (model_id, game_id) → models (id, game_id)` and
`FOREIGN KEY (season_id, game_id) → seasons (id, game_id)`, a version cannot belong to one game's
entry and another game's season — a disagreement the schema could not previously notice at all.

Every rule that was scoped `(owner_id, game_id)` is scoped `model_id`:

```sql
model_versions_model_version_uniq    (model_id, version)          -- numbers restart per entry
model_versions_one_in_flight_uniq    (model_id) WHERE status IN ('testing', 'verified')
model_versions_release_uniq          (model_id, season_id, release_tag)
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

`adapter` is the document as the competitor shipped it — the exact bytes of the release asset, as
`text` rather than `jsonb`, because jsonb normalises key order and whitespace and the stored form
would no longer hash to `adapter_hash`. Stored as text, the constraint makes the row's copy
self-verifying. The play path never reads it — the loader fetches by hash from the object store —
so it serves the Version screen, an operator with `psql`, and the re-validation sweep.

### 3.3 `matches` — one row per match, the facts that are about the match

```sql
CREATE TABLE matches (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid         NOT NULL REFERENCES games (id),
    status               match_status NOT NULL DEFAULT 'pending',
    created_at           timestamptz  NOT NULL DEFAULT now(),

    -- what to play — Jodi's pair clock, at insert
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
    evaluator_digest     text,
    replay_key           text,                       -- names the attempt: …/{id}/{claim_token}.json
    played_at            timestamptz,                -- when the match ended
    fault_reason         text,                       -- on failed
    fault_seat           smallint,                   -- the seat a fault is attributed to
    closed_at            timestamptz,                -- failed or cancelled

    -- why it will not be played — Jodi
    withdrawn_reason     text,
    successor_version_id         uuid         REFERENCES models (id),

    -- what it did to the ladder — Jodi's count clock
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
                              AND evaluator_digest IS NOT NULL AND rated_at IS NULL
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
    adapter_hash   text     NOT NULL,
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
| `weights_hash`, `adapter_hash` on the seat | Kalam is roster-blind and its role cannot read `models`; the hashes are the loader's identity for a seat, so they travel with the seat |
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
every insert. Which of `pair` and `withdraw` claim a run fence is Jodi's; the rows cost nothing.

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
              reason, turns, played_ms, engine_digest_played, evaluator_digest,
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

### 3.9 Seeds

`games.active_engine_digest = 'sha256:placeholder'` for `ants`, overwritten by the deploy step;
the four `clocks` rows above; the three baseline users and a `models` row each. The seed is
`devops/compose/db-init/30-seed.sql`'s and is listed here only so the first pair run has a digest to
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
| `repo_path(text)` | a GitHub URL, ssh remote or bare `owner/name` normalised to one canonical path; NULL for anything that is not exactly one repository | the `models.repo` CHECK, the entry create, the submission |
| `repo_owned(repo, handle, rules)` | whether a repository is the competitor's to enter | the entry create, through `season_admits_repo` |
| `season_rule_spec()` | **what a season's rules document may say**: one row per key, with its kind and range | `season_rules_ok` |
| `season_rules_ok(jsonb)` | the rules document's shape, refusing an unknown key at both levels | the `seasons.rules` CHECK |
| `season_rules_public(jsonb)` | the rules a season may show the world | `season_json` |
| `season_admits*` ×7 | one predicate per rule: participants, weights, repository, entries, in-flight, versions, class | the writes that must not happen, and the reads that say why |
| `season_cooldown_until(season, model)` | when a model may submit again | the submission `why` read |
| `weight_classes_ok(jsonb)` | what a weight-class table must be: named classes, positive whole caps, strictly ascending | the `seasons.weight_classes` CHECK |

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
ceiling, and it used to be plumbed from Jodi's `[vars]` through every Soma route that called it —
so Soma's rendering of a forfeit depended on a number in another package's config. It is read off
`matches.strike_ceiling` now: the rule the wave actually played by, and nothing else.

---

## 4. Kalam's statements

Every one conditioned on the claim token, so a stale attempt updates nothing (principle 4).
Parameters: `$engine` from `[vars]`, `$resident` from the loader, `$K` and `$lease` from Kalam,
`$token` minted per claim with `{"random": ["uuid"]}`.

### 4.1 Reap — `db_write`, first task of every claim occurrence

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
claim in the same snapshot: folded in, a reaped row would wait one more poll to be claimed. Two
round trips per poll is the cost; the claim-under-load spike prices it, and folding is a
one-line change if it matters. `rows_affected` is worth a metric: it counts crashes.

### 4.2 Claim — `db_write`

```sql
WITH first AS MATERIALIZED (
    SELECT m.id, m.preset
      FROM matches m
     WHERE m.status = 'pending' AND m.engine_digest = ($1)::text
     ORDER BY (m.trial_version_id IS NOT NULL) DESC,                    -- trials first
              EXISTS (SELECT 1 FROM match_seats s                      -- then what this loader holds
                       WHERE s.match_id = m.id
                         AND s.weights_hash = ANY (($2)::text[])) DESC,
              m.created_at, m.id
     LIMIT 1
       FOR UPDATE SKIP LOCKED
), wave AS MATERIALIZED (
    SELECT m.id
      FROM matches m, first f
     WHERE m.status = 'pending' AND m.engine_digest = ($1)::text
       AND m.preset = f.preset                                          -- one preset per wave (decision 18)
       AND (m.id = f.id
            OR EXISTS (SELECT 1 FROM match_seats a                      -- rows sharing the first row's models
                         JOIN match_seats b ON b.weights_hash = a.weights_hash
                        WHERE a.match_id = f.id AND b.match_id = m.id))
     ORDER BY (m.id = f.id) DESC, (m.trial_version_id IS NOT NULL) DESC, m.created_at, m.id
     LIMIT ($3)::int
       FOR UPDATE OF m SKIP LOCKED
)
UPDATE matches m
   SET status           = 'claimed',
       claim_token      = ($4)::uuid,
       lease_expires_at = now() + ($5)::int * interval '1 second'
  FROM wave
 WHERE m.id = wave.id
```

`$1` engine digest · `$2` resident weights hashes, `text[]` · `$3` K · `$4` token · `$5` lease
seconds. Trial priority and affinity choose the first row; the wave is filled with rows that share
its models and its preset, so one inference serves the wave by construction (finding 9–11).
`SKIP LOCKED` is the whole of coordination between replicas. `rows_affected` is the wave size;
zero ends the run.

### 4.3 Read the wave — `db_read`

> **REVISED BY THE BUILD, 8 September 2026: this is TWO reads, and it has to be.** The statement
> below reads the *claimed* rows, and Kalam §4.1 asked it to number them. It cannot do both jobs
> at once, because the barrier between them changes which rows there are: a row refused by the
> loader is released or failed, and if `m` was assigned before that, the engine — which indexes its
> matches `0..n_started-1` — and the refs — which still carry `0..n_claimed-1` — disagree. `observe`
> matches a ref on `(m, seat)`, so the mismatch is silent: every view arrives with no ref, the play
> row names no model, and the wave plays a thousand turns against nothing. So:
>
> * **before the barrier**, one read of the wave's *models*, which is all the hold needs and needs
>   no numbering at all:
>
>   ```sql
>   SELECT DISTINCT s.weights_hash, s.adapter_hash
>     FROM matches m JOIN match_seats s ON s.match_id = m.id
>    WHERE m.claim_token = ($1)::uuid AND m.status = 'claimed'
>    ORDER BY s.weights_hash, s.adapter_hash
>   ```
>
> * **after `start`**, the numbered read, filtered on `'running'` so `m` numbers exactly the rows
>   that will be played, with `m` repeated onto every seat because the refs are a flat list matched
>   on `(m, seat)`:
>
>   ```sql
>   WITH w AS (
>       SELECT m.id, m.seed, m.preset, m.seat_count, m.trial_version_id,
>              (row_number() OVER (ORDER BY m.id) - 1)::int AS m
>         FROM matches m
>        WHERE m.claim_token = ($1)::uuid AND m.status = 'running'
>   )
>   SELECT json_build_object('m', w.m, 'id', w.id, 'seed', w.seed, 'preset', w.preset,
>            'seat_count', w.seat_count, 'trial_version_id', w.trial_version_id,
>            'seats', (SELECT json_agg(json_build_object('m', w.m, 'seat', s.seat,
>                         'model_id', s.version_id, 'weights_hash', s.weights_hash,
>                         'adapter_hash', s.adapter_hash) ORDER BY s.seat)
>                        FROM match_seats s WHERE s.match_id = w.id)) AS row
>     FROM w ORDER BY w.m
>   ```
>
> Both ship in `kalam/workflows/tb-wave-run.json` and are PREPAREd by `kalam/scripts/check-sql.sh`.
> The form below is kept because it is what the two were derived from.

```sql
SELECT json_build_object(
         'id', m.id, 'seed', m.seed, 'preset', m.preset, 'trial_version_id', m.trial_version_id,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.version_id,
                      'weights_hash', s.weights_hash, 'adapter_hash', s.adapter_hash)
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row
  FROM matches m
 WHERE m.claim_token = ($1)::uuid AND m.status = 'claimed'
 ORDER BY m.id
```

Postgres builds the shape, as every Soma read does; the workflow decodes no arrays.

### 4.4 Start, release, fail — after the residency barrier

> **REVISED BY THE BUILD, 8 September 2026: the barrier's unit is a MODEL, not a row.** All three
> statements below take `id = ANY(($2)::uuid[])`, which assumes the workflow can turn "the loader
> refused this model" into "these rows seat it". It cannot: the loader answers about
> `(weights_hash, adapter_hash)` pairs, and joining a refused pair back to the rows that name it is
> a join from element scope into root scope — the one thing this JSONLogic dialect has no way to
> express (`03-spike/FINDINGS.md` §2.6). Postgres does the join instead, which also makes `start`
> need no list at all:
>
> ```sql
> -- release: $2 is the refused weights hashes, text[]
> UPDATE matches SET … WHERE claim_token = ($1)::uuid AND status = 'claimed'
>    AND EXISTS (SELECT 1 FROM match_seats s
>                 WHERE s.match_id = matches.id AND s.weights_hash = ANY (($2)::text[]))
>
> -- fail, set-valued: $2 is [{weights_hash, reason}], and DISTINCT ON picks the lowest
> -- offending seat when a row has more than one
> UPDATE matches m SET status = 'failed', fault_reason = x.reason, fault_seat = x.seat,
>        closed_at = now(), lease_expires_at = NULL
>   FROM (SELECT DISTINCT ON (s.match_id) s.match_id, s.seat, v.reason
>           FROM jsonb_to_recordset(($2)::jsonb) AS v (weights_hash text, reason text)
>           JOIN match_seats s ON s.weights_hash = v.weights_hash
>          ORDER BY s.match_id, s.seat) AS x
>  WHERE m.id = x.match_id AND m.claim_token = ($1)::uuid AND m.status = 'claimed'
>
> -- start: everything still claimed once those two have run
> UPDATE matches SET status = 'running' WHERE claim_token = ($1)::uuid AND status = 'claimed'
> ```
>
> This is also Kalam §4.2's ask for a set-valued named-fault statement, answered in a better
> shape than the one it asked for. The single-row form stays correct for a fault attributed
> mid-play — though see Axon §3.2: the built `/play` reply has no `fault` field, so there is at
> present no signal to attribute one on.

```sql
-- the rows the loader holds
UPDATE matches SET status = 'running'
 WHERE claim_token = ($1)::uuid AND status = 'claimed' AND id = ANY (($2)::uuid[])
```

```sql
-- refused for want of memory: back to the queue, no lapse spent, under its own ceiling
UPDATE matches
   SET status           = CASE WHEN refusals + 1 >= ($3)::int THEN 'failed' ELSE 'pending' END::match_status,
       refusals         = refusals + 1,
       claim_token      = NULL,
       lease_expires_at = NULL,
       fault_reason     = CASE WHEN refusals + 1 >= ($3)::int THEN 'UNLOADABLE' END,
       closed_at        = CASE WHEN refusals + 1 >= ($3)::int THEN now() END
 WHERE claim_token = ($1)::uuid AND status = 'claimed' AND id = ANY (($2)::uuid[])
```

```sql
-- refused by name, or a fault mid-play that Kalam can attribute: failed at once, with the seat
UPDATE matches
   SET status               = 'failed',
       fault_reason         = ($3)::text,
       fault_seat           = ($4)::smallint,
       closed_at            = now(),
       engine_digest_played = ($5)::text,
       evaluator_digest     = ($6)::text,
       lease_expires_at     = NULL
 WHERE claim_token = ($1)::uuid AND id = ($2)::uuid AND status IN ('claimed', 'running')
```

### 4.5 Renew — every N turns

```sql
UPDATE matches
   SET lease_expires_at = now() + ($2)::int * interval '1 second'
 WHERE claim_token = ($1)::uuid AND status = 'running'
```

Zero rows: the lease was reaped and the wave belongs to someone else — halt and release the
models (finding 7b). Fewer rows than live matches is Kalam's to rule on. This is the statement
the fill factor exists for: no indexed column changes, so it is heap-only.

### 4.6 Finish — one statement per row, as its match ends

```sql
WITH m AS (
    UPDATE matches
       SET status               = 'finished',
           reason               = ($4)::text,
           turns                = ($5)::int,
           played_ms            = ($6)::int,
           engine_digest_played = ($7)::text,
           evaluator_digest     = ($8)::text,
           replay_key           = ($9)::text,
           played_at            = now(),
           lease_expires_at     = NULL
     WHERE id = ($2)::uuid AND claim_token = ($1)::uuid AND status = 'running'
       AND (SELECT count(DISTINCT v.seat)                                -- the result names every seat once
              FROM jsonb_to_recordset(($3)::jsonb) AS v (seat smallint)
             WHERE v.seat BETWEEN 0 AND seat_count - 1) = seat_count
 RETURNING id
)
UPDATE match_seats s
   SET rank = v.rank, score = v.score, strikes = v.strikes,
       infer_us_total = v.infer_us_total, infer_us_max = v.infer_us_max,
       infer_turns = v.infer_turns
  FROM m,
       jsonb_to_recordset(($3)::jsonb) AS v (seat smallint, rank smallint, score int,
                                             strikes smallint, infer_us_total bigint,
                                             infer_us_max int, infer_turns int)
 WHERE s.match_id = m.id AND s.seat = v.seat
```

> **One change from the build:** `played_ms` is not passed in, it is computed here from a new `$6`
> — the instant the wave opened, which the workflow captures with Orion's `{"now": []}` and carries
> in `data`. Postgres has the other end of the subtraction, so it happens where both are exact:
> `played_ms = GREATEST(0, (EXTRACT(EPOCH FROM (now() - ($6)::timestamptz)) * 1000)::int)`. Every
> match in a wave opens together, so this is the match's own duration. The later parameters shift
> by one accordingly.

`$1` token · `$2` match · `$3` the result, one element per seat:
`[{"seat": 0, "rank": 1, "score": 10, "strikes": 0, "infer_us_total": 78360, "infer_us_max": 1001,
"infer_turns": 150}, …]`, forfeited seats ranked last (finding
12.5) · `$4` the engine's end reason · `$5`, `$6` turns and duration · `$7`, `$8` the digests that
played it · `$9` the replay key. `rows_affected` is `seat_count`; zero means the token is stale or
the result is malformed, and in both cases nothing was written. The replay `PUT` precedes it under
a key naming the token, so a stale attempt's blob is an orphan under its own key rather than a
replacement (finding 7d). `claim_token` stays on the finished row: it is the attempt that counted.

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
missing, which Jodi alerts on rather than halts. A run applying the same match twice from one
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

The rules are finding 6b's; the words are Jodi's. Three outcomes, three statements:

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
inflation — provisional from Jodi, final from 06. `rows_affected` is 2, the two `seq = 0`
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
Jodi's number without a pass, the reject statement runs with the unplayable reason.

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

Held in `data` for the run. The demand view and the depth read are Jodi's.

### 6.2 The fenced insert — one per match, the match and its seats in one statement

```sql
WITH seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, md.id AS model_id, md.weights_hash, md.adapter_hash, md.weight_class
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
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, adapter_hash, paired_ratings)
SELECT m.id, s.seat, s.version_id, s.weights_hash, s.adapter_hash,
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
mark, the reap as its own statement, `models.adapter` as exact text, and the schema being initial
rather than a migration chain.

Each is recorded with its reasoning and the cost of flipping it in
[devops/docs/decisions.md](https://github.com/Tiny-Brains/devops/blob/main/docs/decisions.md) §3,
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
- **The adapter copy** is accepted when its text hashes to `adapter_hash` and refused by
  `model_versions_adapter_matches_hash` when one byte differs.
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
2. **The fence on a cron channel** (tracker §4): §5.1 from `metadata.trigger`, and a manual trigger
   forced to overlap a running occurrence with `forbid` off, halting on zero rows. The Postgres
   half is 9.1; the Orion half — the metadata, the halt, what a dead node costs under the channel
   timeout — is the spike's.
3. **The claim under load** (tracker §4). Several pollers on §4.2 against a queue of thousands:
   whether the two `EXISTS` on `match_seats` in the ordering and the fill cost more than the
   partial index saves, whether the `ORDER BY` needs splitting into a trials query and a
   fallback, and whether the reap should fold into the claim.

---

## 10. Open questions

Beyond the §8 decisions, three things the review did not reach:

1. **`reason` on a `finished` row** stays the engine's free text (schema §5). Kalam must say
   whether a forfeit overwrites it or is inferred from the seat's `strikes` — the rows carry both.
2. **`paired_ratings`' content** is derived here from `ratings` at insert; whether the pairing
   plugin wants more recorded — the demand it answered, the fraction it drew — is Jodi's.
3. **Trial rows and the count fence.** A `failed` or `cancelled` trial is never marked; count
   decides it from `models.status = 'verified'` and re-decides idempotently. That is simpler than
   a mark but means the verdict read in §5.3 scans `verified` models every run — cheap under
   one-in-flight, and worth stating.
