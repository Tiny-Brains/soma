-- Soma — initial schema, v2.
--
-- Transcribed from design/v2/01-match-table.md §3 (layer 01 draft 3, agreed and verified on
-- Postgres 16 by design/v2/01-verify/run.sh), which supersedes schema.md for everything below
-- `ratings`. Postgres 13+ (gen_random_uuid is built in).
--
-- There is no 0003: nothing is released, so there is no migration chain to keep. This file IS
-- the schema. `01-verify/01_schema.sql` was the delta over the pre-v2 files and is now history;
-- the harness that applies it stays the CI check.
--
-- Three writers share this database, and each is confined by what it can reach:
--
--   Soma   — users, sessions, the INSERT of a models row, and (as Jodi, three cron channels in
--            the same Orion package) matches, match_seats, rating_events, ratings and clocks.
--   Kalam  — the match players. A separate role, granted SELECT on matches and match_seats and
--            UPDATE on named columns of each. It can reach no other table and no other column,
--            so "Kalam writes no rating" is a fact of the grant, not a convention. See §3.8.
--   the Model Loader — no database access at all. It is called over loopback HTTP.
--
-- Nothing above is trusted to enforce one-active-version, one-submission-in-flight, or
-- one-live-trial. The partial unique indexes and the exclusion constraint at the bottom are.
--
-- SEASONS -- design/v2/06-rating-seasons.md (layer 06 draft 3, agreed 8 September 2026). A season is
-- an admin-created competition window for one game; a version belongs to exactly one season; a
-- season closes itself when its scores have settled; its standings are kept for ever. Layer 06's
-- statements are verified by design/v2/06-verify/run.sh.

BEGIN;

-- ---------------------------------------------------------------- enumerations

CREATE TYPE user_role AS ENUM ('competitor', 'admin', 'baseline');

-- 'open' is a ladder, not a weight class: every model competes in its own class
-- and in open. models.weight_class is CHECKed against it below.
CREATE TYPE ladder AS ENUM ('nano', 'micro', 'mini', 'small', 'large', 'open');

-- 'verified' sits between 'testing' and 'active': admission has checked the release and the
-- adapter, and the version is now waiting for its trial match. It is a status of its own rather
-- than a derived signal so that pair, count and withdraw can each test the status alone
-- (decision 21, layer 01 §3.2). A version is "contesting" when it is 'active', or 'verified' for
-- the candidate seat of its own trial row.
CREATE TYPE model_status AS ENUM ('testing', 'verified', 'active', 'superseded', 'rejected');

-- A match's life. 'pending' is born by pair; Kalam takes it through 'claimed' and 'running' to
-- 'finished'; count marks it 'rated'. 'cancelled' is withdraw's, 'failed' is a fault's — both
-- terminal, neither counted.
CREATE TYPE match_status AS ENUM
    ('pending', 'claimed', 'running', 'finished', 'rated', 'cancelled', 'failed');

-- ---------------------------------------------------------------------- games

-- Also the fleet table: one game, one server.
CREATE TABLE games (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                 text        NOT NULL UNIQUE,
    name                 text        NOT NULL,

    -- The engine the deploy step declares current, written once the replicas carrying it exist
    -- (finding 5 option A). A SEASON PINS A COPY at creation (layer 06 §4.4): pair stamps rows
    -- from the season's copy, withdraw retires rows against it, and Kalam claims only rows naming
    -- its own digest. A behaviour-preserving patch updates both; a rules change is refused while a
    -- season is live and enters with the next season. The two columns differing is a fact -- a
    -- release waiting for the next season -- not a drift.
    active_engine_digest text,

    -- THE CARTRIDGE'S REGISTRATION DATA -- decision 38, layer 08 §8. Two documents published by
    -- whoever wrote the cartridge, read by admission and by nothing else today.
    --
    -- `manifest` is DESIGN.md §3's declaration verbatim: abi, game, version, presets, limits,
    -- budgets. Admission reads budgets.adapter_ops_max and budgets.flop_caps from it, and they
    -- live HERE rather than in Jodi's [vars] because they are per game by construction -- a
    -- 128x128 Ants board and a card game have nothing in common -- so a second cartridge must be
    -- content and not a config change. Pair's presets could come from it too and eventually
    -- should; moving them is a change to a running clock for no gain layer 08 needs.
    manifest             jsonb,

    -- The observations admission validates an adapter against, in the game's own state shape.
    -- THE WORST CASE MUST BE IN HERE -- the largest preset, the most units -- or the gate is
    -- theatre: the operation budget is checked per call during a real match, so an adapter
    -- validated only against a small sample and then struck every turn has been admitted by a
    -- check that did not test it. Layer 04 §3.6 states the requirement; this column is its answer.
    reference_observations jsonb,

    created_at           timestamptz NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------- seasons

-- Layer 06 §4: a competition window for one game, created by an admin. The owner's four rules:
--   1. an admin creates a season for each game, with its submission window and its rules;
--   2. a submission belongs to a season (models.season_id, stamped at POST /v1/submissions);
--   3. seasons of a game never overlap -- at most one is LIVE (closed_at IS NULL), by the partial
--      unique index below -- and the next opens at least season_gap_days after the previous closed;
--   4. a season closes itself when its scores have settled (withdraw's second task, 06 §5.2), or
--      when an admin asks (close_requested_at).
-- And the fifth: its standings are its `active` versions and their `ratings` rows, kept for ever.
--
-- Four states, derived from three timestamps rather than kept in a column (06 §4.2):
--   closed     closed_at IS NOT NULL
--   scheduled  now() <  submissions_open_at
--   open       now() <  submissions_close_at
--   settling   otherwise
CREATE TABLE seasons (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid        NOT NULL REFERENCES games (id),
    number               int         NOT NULL,                       -- 1, 2, ... per game

    -- Pinned from games.active_engine_digest at creation (06 §4.4).
    engine_digest        text        NOT NULL,

    submissions_open_at  timestamptz NOT NULL,                       -- the gap is checked here (rule 3)
    submissions_close_at timestamptz NOT NULL,                       -- the last submission date (rule 4)
    closed_at            timestamptz,                                -- set by the close, once

    -- An admin's request to close, consumed by the close on withdraw's next tick. Stays set on the
    -- closed row as the record that the close was asked for rather than reached.
    close_requested_at   timestamptz,

    -- The season's submission rules (06 §4.8): one document, each rule under its own key with an
    -- `enabled` flag, so a rule is turned on or off per season without a schema change. Checked
    -- as predicates in the submission insert itself. Two rules exist:
    --   unique_weights  { enabled, scope: 'game' | 'season' }  -- no two users hold one weights hash
    --   participants    { enabled, user_ids: [...] }           -- only the listed users may submit
    -- The check refuses a key this schema does not name, so a misspelt rule fails loudly.
    rules                jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- The TinyBrain Index's lambda, fitted and published per season (DESIGN.md §9). P7's.
    lambda               float8,

    created_at           timestamptz NOT NULL DEFAULT now(),

    UNIQUE (game_id, number),
    CONSTRAINT seasons_number_positive CHECK (number >= 1),
    CONSTRAINT seasons_window          CHECK (submissions_close_at > submissions_open_at),
    CONSTRAINT seasons_rules_known     CHECK (jsonb_typeof(rules) = 'object'
                                          AND (rules - 'unique_weights' - 'participants') = '{}'::jsonb)
);

-- Rule 3: at most one live season per game. This IS the non-overlap rule, as an index.
CREATE UNIQUE INDEX seasons_one_live_uniq ON seasons (game_id) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------- users

-- Baselines are users: one per reference opponent, so three baselines can be
-- told apart on a ladder where a model is displayed as its owner's handle.
-- They never sign in, hence the nullable github_id.
CREATE TABLE users (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    github_id   bigint      UNIQUE,
    handle      text        NOT NULL UNIQUE,
    role        user_role   NOT NULL DEFAULT 'competitor',
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_human_has_github_id
        CHECK (role = 'baseline' OR github_id IS NOT NULL)
);

-- --------------------------------------------------------------------- models

-- One row per submission. Everything from commit_sha down is null at insert: a submission names
-- a GitHub release and cannot state its own size, class or hashes. The admission workflow fills
-- them, then moves the row 'testing' -> 'verified'. Promotion to 'active' is count's, after the
-- trial match is played.
CREATE TABLE models (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        uuid         NOT NULL REFERENCES users (id),
    game_id         uuid         NOT NULL REFERENCES games (id),

    -- Rule 2: a version belongs to exactly one season. Stamped by POST /v1/submissions from the
    -- game's OPEN season, or by the season create for a carried baseline; never changed. A closed
    -- season's `active` versions are its final standing, which is why the one-active rule and the
    -- release-uniqueness rule below are per season.
    season_id       uuid         NOT NULL REFERENCES seasons (id),
    version         int          NOT NULL,

    repo            text         NOT NULL,
    release_tag     text         NOT NULL,
    commit_sha      text,

    status          model_status NOT NULL DEFAULT 'testing',

    weight_class    ladder,
    size_bytes      bigint,
    param_count     bigint,
    flops_estimate  bigint,
    weights_hash    text,
    adapter_hash    text,

    -- The adapter as the release asset's exact text, stored rather than referenced: it is small,
    -- it is what the evaluator runs, and holding the bytes means a re-validation sweep after a
    -- dialect change needs no network. The CHECK below makes the stored text and the recorded
    -- hash impossible to disagree.
    adapter          text,

    -- Which evaluator build verified this version. Reported by the loader on every call; a change
    -- in it is what makes the re-validation sweep necessary (finding 5).
    evaluator_digest text,

    reject_reason   text,

    -- THE ADMISSION CLAIM -- layer 08 §4. Admission needs no run fence the way count does: it
    -- writes one row per item, so this per-row claim IS the mutual exclusion, and it is strictly
    -- better than a fence here because a run that dies mid-batch releases what it had not reached
    -- at once and the row it held after admit_timeout_s. The verdict statement re-checks
    -- admit_token, so a run whose claim lapsed while it was verifying writes nothing.
    --
    -- admit_attempts counts REAL attempts: a loader-class fault (the store is down, GitHub 5xx)
    -- releases the claim and decrements it, because an outage must not consume a competitor's
    -- three tries. At admit_attempts_max the row is rejected TIMED_OUT -- the one rejection word
    -- that does not mean "your model is wrong".
    admit_started_at timestamptz,
    admit_token      uuid,
    admit_attempts   int          NOT NULL DEFAULT 0,

    created_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT models_weight_class_not_open
        CHECK (weight_class <> 'open'),

    CONSTRAINT models_version_positive
        CHECK (version >= 1),

    -- Past 'testing', a row must know what it is. This is what stops a half-verified version
    -- being paired: pair joins on status and would otherwise seat a null weights_hash.
    CONSTRAINT models_past_testing_has_contents
        CHECK (status IN ('testing', 'rejected')
            OR (weights_hash IS NOT NULL AND adapter_hash IS NOT NULL
                AND evaluator_digest IS NOT NULL AND weight_class IS NOT NULL)),

    CONSTRAINT models_adapter_matches_hash
        CHECK (adapter IS NULL
            OR adapter_hash = 'sha256:' || encode(sha256(convert_to(adapter, 'UTF8')), 'hex'))
);

-- -------------------------------------------------------------------- ratings

-- Two rows per promoted model: its weight class, and open.
-- Created at promotion, so a testing, verified or rejected model has none.
--
-- seed_mu / seed_sigma record what this version inherited from the one it
-- replaced, at the instant it was promoted. They are not derivable: the
-- predecessor keeps rating on matches already in flight, so its final mu is
-- not the number its successor started from.
CREATE TABLE ratings (
    model_id        uuid    NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    ladder          ladder  NOT NULL,

    mu              float8  NOT NULL,
    sigma           float8  NOT NULL,
    conservative    float8  GENERATED ALWAYS AS (mu - 3 * sigma) STORED,

    seed_mu         float8,
    seed_sigma      float8,

    matches_played  int         NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (model_id, ladder)
);

-- -------------------------------------------------------------------- matches

-- A match is born 'pending' by pair, with everything needed to play it and nothing about how it
-- went. Kalam claims it with a token, plays it, and finishes it in place. Count marks it 'rated'.
--
-- The row is the unit of work AND the unit of idempotence: there is no separate claims table and
-- no id derived from an occurrence. `claim_token` is what makes a stale replica's finish a no-op,
-- and `rated_seq` is what makes a second fold of the same match impossible.
CREATE TABLE matches (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid         NOT NULL REFERENCES games (id),
    status               match_status NOT NULL DEFAULT 'pending',
    created_at           timestamptz  NOT NULL DEFAULT now(),

    -- ---- what pair decides, and what it takes to reproduce the match
    season_id            uuid         NOT NULL REFERENCES seasons (id),   -- the live season at insert
    engine_digest        text         NOT NULL,   -- which engine must play it: the season's copy
    seed                 bigint       NOT NULL,
    preset               text         NOT NULL,
    seat_count           smallint     NOT NULL,
    ladders              ladder[]     NOT NULL,   -- derived at insert; empty for a trial
    trial_model_id       uuid         REFERENCES models (id),
    pairing_id           uuid,                    -- the pairing run that proposed it, for audit

    -- ---- the lease
    claim_token          uuid,
    lease_expires_at     timestamptz,
    lapses               smallint     NOT NULL DEFAULT 0,   -- leases that expired mid-play
    refusals             smallint     NOT NULL DEFAULT 0,   -- loader refusals for want of memory

    -- ---- what Kalam reports
    reason               text,        -- free text, never an enum: game-defined
    turns                int,
    played_ms            int,
    engine_digest_played text,        -- what actually ran; compare with engine_digest for skew
    evaluator_digest     text,
    replay_key           text,        -- names the attempt, so a stale attempt's blob is an orphan
    played_at            timestamptz,
    fault_reason         text,
    fault_seat           smallint,    -- which seat is to blame, when one is
    closed_at            timestamptz,

    -- ---- what withdraw reports
    withdrawn_reason     text,
    successor_id         uuid         REFERENCES models (id),

    -- ---- what count reports
    rated_at             timestamptz,
    rated_seq            bigint,

    CONSTRAINT matches_seat_count         CHECK (seat_count >= 2),
    CONSTRAINT matches_fault_seat_in_range
        CHECK (fault_seat IS NULL OR fault_seat BETWEEN 0 AND seat_count - 1),
    CONSTRAINT matches_lapses_bounded     CHECK (lapses BETWEEN 0 AND 3),

    -- The status and the columns that go with it cannot disagree. This is also what confines
    -- Kalam: with UPDATE granted on its columns only, there is no state it can reach that is not
    -- one of its own -- it cannot mark a row 'rated', because it cannot write rated_at.
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

-- The order count folded matches in. A global sequence rather than a timestamp: two matches can
-- share a played_at to the microsecond, and the audit needs a total order.
CREATE SEQUENCE rating_seq AS bigint;

-- ---------------------------------------------------------------- match_seats

-- One row per seat, not arrays and not one jsonb document (decision 2, layer 01 §8). Arrays
-- cannot be foreign-keyed, so a seat could name a model that does not exist or one from another
-- game; a table can, and does. It is also what makes "every match this version played" an index
-- scan rather than a containment search over every row in the table.
--
-- seat IS the index: seat 0 is the first player, the same addressing docs/PROTOCOL.md uses.
CREATE TABLE match_seats (
    match_id       uuid     NOT NULL REFERENCES matches (id) ON DELETE CASCADE,
    seat           smallint NOT NULL,

    -- ---- what pair writes
    model_id       uuid     NOT NULL REFERENCES models (id),
    weights_hash   text     NOT NULL,   -- copied at insert: the row records what was paired,
    adapter_hash   text     NOT NULL,   -- not what the model row says today
    paired_ratings jsonb,               -- the rating snapshot the pairing was made on

    -- ---- what Kalam writes
    rank           smallint,            -- 1 = best; ties allowed; forfeits last
    score          int,                 -- integer by law: game state carries no floats
    strikes        smallint,

    PRIMARY KEY (match_id, seat),
    CONSTRAINT match_seats_seat_nonneg    CHECK (seat >= 0),
    CONSTRAINT match_seats_result_whole   CHECK ((rank IS NULL) = (score IS NULL)
                                             AND (rank IS NULL) = (strikes IS NULL)),
    CONSTRAINT match_seats_rank_positive  CHECK (rank IS NULL OR rank >= 1),
    CONSTRAINT match_seats_strikes_nonneg CHECK (strikes IS NULL OR strikes >= 0)
);

-- -------------------------------------------------------------- rating_events

-- One row per seat per ladder per counted match, plus a seed row at promotion (seq = 0).
-- Decision 22, taken early because the fold writes the rows anyway.
--
-- The primary key IS the correctness argument (finding 1, option B'): (model_id, ladder, seq)
-- with seq taken from ratings.matches_played means a second fold of the same match collides
-- rather than double-counting. The chain -- every event starting where the previous one on its
-- ladder ended -- is then checkable by a join, which is what `a_chain` in 01-verify does.
CREATE TABLE rating_events (
    model_id     uuid        NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    ladder       ladder      NOT NULL,
    seq          int         NOT NULL,
    match_id     uuid        REFERENCES matches (id),
    seat         smallint,
    mu_before    float8,
    sigma_before float8,
    mu_after     float8      NOT NULL,
    sigma_after  float8      NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (model_id, ladder, seq),
    FOREIGN KEY (match_id, seat) REFERENCES match_seats (match_id, seat),
    CONSTRAINT rating_events_seq_nonneg CHECK (seq >= 0),

    -- seq 0 is the seed at promotion: no match, no before. Everything else is a fold: both.
    CONSTRAINT rating_events_seed_shape
        CHECK ((seq = 0) = (match_id IS NULL)
           AND (seq = 0) = (mu_before IS NULL)
           AND (mu_before IS NULL) = (sigma_before IS NULL)
           AND (match_id IS NULL) = (seat IS NULL))
);

-- --------------------------------------------------------------------- clocks

-- One table, two flavours of fence (layer 01 §3.6).
--
--   run fence   -- (scheduled_for, attempt). A cron run claims it at its first task with its own
--                  occurrence's identity, monotonically; every ladder write in the run then reads
--                  the row FOR SHARE and writes nothing if it has moved. A run that lost the race
--                  provably writes nothing. Used by `count`.
--   epoch fence -- a counter any roster writer bumps. Pair reads it at run start and every insert
--                  checks it FOR SHARE, so a pairing decided against a roster that has since
--                  changed cannot land. Used by `roster`.
--
-- `pair` and `withdraw` are seeded as run fences that nothing currently claims: pair's guarantee
-- is the roster epoch (a stale run overfills by at most one run's worth, which the depth target
-- bounds), and withdraw's single statement is idempotent. The rows cost nothing and are here if
-- either ever needs one.
CREATE TABLE clocks (
    key           text        PRIMARY KEY,
    scheduled_for timestamptz NOT NULL DEFAULT '-infinity',
    attempt       int         NOT NULL DEFAULT 0,
    epoch         bigint      NOT NULL DEFAULT 0,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO clocks (key) VALUES ('count'), ('pair'), ('withdraw'), ('roster');

-- -------------------------------------------------------------------- indexes

-- models --------------------------------------------------------------------

-- versions are unambiguous per entry
CREATE UNIQUE INDEX models_owner_game_version_uniq
    ON models (owner_id, game_id, version);

-- At most one submission in flight, where "in flight" now spans both pre-active states: a
-- competitor with a verified version waiting for its trial may not submit another.
CREATE UNIQUE INDEX models_one_in_flight_uniq
    ON models (owner_id, game_id) WHERE status IN ('testing', 'verified');

-- the same release cannot be entered twice IN ONE SEASON; it may be entered again in the next
CREATE UNIQUE INDEX models_owner_game_release_uniq
    ON models (owner_id, game_id, season_id, repo, release_tag);

-- the admission claim: testing rows, oldest first. The mirror of matches_pending_claim_idx, and
-- deliberately WITHOUT admit_started_at -- a claim rewrites that column on every row it takes and
-- keeping it out of the index leaves those updates heap-only.
CREATE INDEX models_admit_claim_idx
    ON models (created_at) WHERE status = 'testing';

-- class ladders, by season; the season_id prefix also serves the open ladder
CREATE INDEX models_season_class_active_idx
    ON models (season_id, weight_class)
    WHERE status = 'active';

-- At most one contesting version -- as a DEFERRABLE exclusion constraint rather than a partial
-- unique index, so that promotion's single statement does not depend on CTE order. Postgres does
-- not order the updates of sibling CTEs, so "activate the candidate" and "supersede the
-- predecessor" can be applied in either order; with the rule checked at commit, both orders
-- succeed. 01-verify runs the statement written both ways to prove it (01 §9.1).
-- Per SEASON (layer 06 §4.5): a closed season's final version stays `active` -- it is the
-- standing -- while the same owner contests the next season with another.
ALTER TABLE models
    ADD CONSTRAINT models_one_active_excl
        EXCLUDE USING btree (owner_id WITH =, game_id WITH =, season_id WITH =)
        WHERE (status = 'active')
        DEFERRABLE INITIALLY DEFERRED;

-- matches -------------------------------------------------------------------

-- the claim: pending rows of one engine, oldest first
CREATE INDEX matches_pending_claim_idx
    ON matches (engine_digest, created_at) WHERE status = 'pending';

-- the in-flight set. Deliberately WITHOUT lease_expires_at: a renew every N turns rewrites that
-- column on every live row, and keeping it out of the index is what leaves those updates
-- heap-only. The reaper scans this index and filters.
CREATE INDEX matches_in_flight_idx
    ON matches (claim_token) WHERE status IN ('claimed', 'running');

-- count's batch: finished, in finish order
CREATE INDEX matches_finished_idx
    ON matches (played_at, id) WHERE status = 'finished';

-- One live trial per candidate. 'finished' is inside the predicate on purpose: a trial that has
-- been played but not yet decided still counts as live, so pair cannot insert a second one in the
-- window between Kalam finishing it and count deciding it.
CREATE UNIQUE INDEX matches_one_live_trial_uniq
    ON matches (trial_model_id)
    WHERE trial_model_id IS NOT NULL AND status IN ('pending', 'claimed', 'running', 'finished');

-- how many trials a candidate has had, for the re-pair cap
CREATE INDEX matches_trial_history_idx
    ON matches (trial_model_id) WHERE trial_model_id IS NOT NULL;

-- match_seats ---------------------------------------------------------------

-- a version's matches: GET /matches?model={id}, and the demand view's in-flight count
CREATE INDEX match_seats_model_idx
    ON match_seats (model_id, match_id);

-- the claim's affinity fill: rows whose models a replica already holds
CREATE INDEX match_seats_weights_idx
    ON match_seats (weights_hash, match_id);

-- rating_events -------------------------------------------------------------

-- the rating change a given match produced, for the Version screen
CREATE INDEX rating_events_match_idx
    ON rating_events (match_id, seat);

-- There is deliberately no index on ratings.conservative. Only active models are ranked, status
-- lives on models, and Postgres cannot build a partial index across a join -- so it would be
-- walked past every superseded and rejected version. The leaderboard is a join filtered by
-- models_season_class_active_idx, sorted afterward.

-- ---------------------------------------------------------------- table storage

-- Every match row is updated at least four times after insert -- claim, start, renew (repeatedly),
-- finish, rate -- and the renews are the reason for the headroom: leaving 30% free gives those
-- updates somewhere on the same page to go, which is what keeps them heap-only and off the
-- indexes. Revisit if vacuum ever says the trade is wrong (finding 12.1 b).
ALTER TABLE matches SET (fillfactor = 70);

-- ------------------------------------------------------------------ the Kalam role

-- Finding 12.2 option (a): confine the match player by grant, not by convention. It can read the
-- two tables it plays from and write only the columns it reports. Combined with
-- matches_status_shape above, there is no state it can reach that is not one of its own -- it
-- cannot rate a match, cancel one, pair one, or touch models, ratings, users or clocks at all.
--
-- Roles are cluster-global while this schema is per-database, which is why the create is guarded.
-- No password is set here: the credential is deployment configuration and lives in devops/, so
-- the committed migration ships no secret. Until one is set the role cannot log in.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kalam') THEN
        CREATE ROLE kalam LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO kalam;
GRANT SELECT ON matches, match_seats TO kalam;
GRANT UPDATE (status, claim_token, lease_expires_at, lapses, refusals,
              reason, turns, played_ms, engine_digest_played, evaluator_digest,
              replay_key, played_at, fault_reason, fault_seat, closed_at)
    ON matches TO kalam;
GRANT UPDATE (rank, score, strikes)
    ON match_seats TO kalam;

COMMIT;
