-- Soma -- the platform schema. One initial file rather than a migration chain: nothing is
-- released, so 0001 is rewritten in place until it is. Postgres 13+.
--
-- Three writers share this database, each confined by its grant (bottom of the file):
--   soma   -- users, sessions, and the INSERT of a models row.
--   jodi   -- the version life cycle: matches, match_seats, ratings, rating_events, clocks.
--   kalam  -- the match player. SELECT on two tables, UPDATE on the columns it reports.
-- Nothing above is trusted to enforce one-active-version, one-submission-in-flight or
-- one-live-trial. The partial unique indexes and the exclusion constraint are.
--
-- Design: docs/schema.md. Verified against Postgres 16 by scripts/verify/run.sh.

BEGIN;

-- ---------------------------------------------------------------- enumerations

CREATE TYPE user_role AS ENUM ('competitor', 'admin', 'baseline');

-- 'open' is a ladder, not a weight class: every model competes in its own class and in open.
CREATE TYPE ladder AS ENUM ('nano', 'micro', 'mini', 'small', 'large', 'open');

-- 'verified' sits between 'testing' and 'active': admission has passed and the version is waiting
-- for its trial match. A status of its own so pair, count and withdraw can each test it alone.
CREATE TYPE model_status AS ENUM ('testing', 'verified', 'active', 'superseded', 'rejected');

-- 'pending' is born by pair; Kalam takes it through 'claimed' and 'running' to 'finished'; count
-- marks it 'rated'. 'cancelled' is withdraw's, 'failed' is a fault's -- both terminal, neither counted.
CREATE TYPE match_status AS ENUM
    ('pending', 'claimed', 'running', 'finished', 'rated', 'cancelled', 'failed');

-- ---------------------------------------------------------------------- games

CREATE TABLE games (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                 text        NOT NULL UNIQUE,
    name                 text        NOT NULL,

    -- The engine the deploy declares current. A SEASON PINS A COPY at creation: pair stamps rows
    -- from the season's copy and Kalam claims only rows naming its own digest, so the two columns
    -- differing is a release waiting for the next season rather than a drift.
    active_engine_digest text,

    -- The cartridge's own registration data, published by whoever wrote it and read by admission:
    -- `manifest` is its declaration (abi, game, presets, limits, budgets), `reference_observations`
    -- the states an adapter is validated against. Per game by construction -- a 128x128 Ants board
    -- and a card game share no budget -- so a second cartridge is content, not a config change.
    manifest             jsonb,
    reference_observations jsonb,

    created_at           timestamptz NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------- seasons

-- What seasons.weight_classes must look like, and the reason everything can trust that column.
-- ASCENDING AND STRICT is the load-bearing clause: admission takes the first class whose cap the
-- size fits, so an out-of-order table silently makes a class unreachable and equal caps make the
-- landing an accident of array order. Neither is an error the database could otherwise notice.
CREATE FUNCTION weight_classes_ok(wc jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_typeof(wc) = 'array'
       AND jsonb_array_length(wc) >= 1
       -- every entry is {class: <a real ladder name>, max_bytes: <a positive whole number>}
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(wc) AS e
           WHERE jsonb_typeof(e) <> 'object'
              OR jsonb_typeof(e -> 'class') IS DISTINCT FROM 'string'
              OR jsonb_typeof(e -> 'max_bytes') IS DISTINCT FROM 'number'
              OR (e ->> 'class') NOT IN ('nano', 'micro', 'mini', 'small', 'large')
              OR (e ->> 'max_bytes')::numeric <= 0
              OR (e ->> 'max_bytes')::numeric <> trunc((e ->> 'max_bytes')::numeric))
       -- no class named twice
       AND (SELECT count(DISTINCT e ->> 'class') FROM jsonb_array_elements(wc) AS e)
           = jsonb_array_length(wc)
       -- strictly ascending by cap, in array order
       AND NOT EXISTS (
           SELECT 1 FROM (
               SELECT (e ->> 'max_bytes')::bigint AS cap,
                      lag((e ->> 'max_bytes')::bigint) OVER (ORDER BY ord) AS prev
               FROM jsonb_array_elements(wc) WITH ORDINALITY AS t (e, ord)) z
           WHERE z.prev IS NOT NULL AND z.cap <= z.prev);
$$;

-- A competition window for one game, created by an admin. A version belongs to exactly one season;
-- seasons of a game never overlap (the partial unique index below IS that rule) and the next opens
-- at least season_gap_days after the previous closed; a season closes when its scores have settled
-- or when an admin asks. Its standings -- its `active` versions and their ratings -- are kept for ever.
CREATE TABLE seasons (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid        NOT NULL REFERENCES games (id),
    number               int         NOT NULL,                       -- 1, 2, ... per game

    engine_digest        text        NOT NULL,   -- pinned from games.active_engine_digest at creation

    submissions_open_at  timestamptz NOT NULL,
    submissions_close_at timestamptz NOT NULL,
    closed_at            timestamptz,                                -- set by the close, once

    -- An admin's request to close, consumed by withdraw's next tick. Stays set on the closed row
    -- as the record that the close was asked for rather than reached.
    close_requested_at   timestamptz,

    -- One document, each rule under its own key with an `enabled` flag, so a rule is turned on or
    -- off per season without a schema change. Checked as predicates in the submission insert.
    --   unique_weights  { enabled, scope: 'game' | 'season' }  -- no two users hold one weights hash
    --   participants    { enabled, user_ids: [...] }           -- only the listed users may submit
    rules                jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- THE ONLY DEFINITION OF THE WEIGHT CLASSES, smallest first. Per season deliberately: a season
    -- can be focused (nano-only, or every cap a notch down) at the price of comparability across
    -- seasons, which is why every route returning a season returns these with it.
    weight_classes       jsonb       NOT NULL DEFAULT
        '[{"class": "nano",  "max_bytes": 8192},
          {"class": "micro", "max_bytes": 65536},
          {"class": "mini",  "max_bytes": 524288},
          {"class": "small", "max_bytes": 4194304},
          {"class": "large", "max_bytes": 67108864}]'::jsonb,

    lambda               float8,     -- the TinyBrain Index's, fitted and published per season

    created_at           timestamptz NOT NULL DEFAULT now(),

    UNIQUE (game_id, number),
    CONSTRAINT seasons_number_positive CHECK (number >= 1),
    CONSTRAINT seasons_window          CHECK (submissions_close_at > submissions_open_at),
    -- Refuses a key this schema does not name, so a misspelt rule fails loudly.
    CONSTRAINT seasons_rules_known     CHECK (jsonb_typeof(rules) = 'object'
                                          AND (rules - 'unique_weights' - 'participants') = '{}'::jsonb),
    CONSTRAINT seasons_weight_classes_shape CHECK (weight_classes_ok(weight_classes))
);

-- At most one live season per game. This IS the non-overlap rule, as an index.
CREATE UNIQUE INDEX seasons_one_live_uniq ON seasons (game_id) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------- users

-- Baselines are users -- one per reference opponent, so they can be told apart on a ladder that
-- displays a model as its owner's handle. They never sign in, hence the nullable github_id.
CREATE TABLE users (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    github_id   bigint      UNIQUE,
    handle      text        NOT NULL UNIQUE,

    -- Seeded from GitHub ON INSERT ONLY: overwriting it at every sign-in would silently undo the
    -- one field PATCH /v1/me lets a competitor edit. Null falls back to the handle.
    display_name text,

    role        user_role   NOT NULL DEFAULT 'competitor',
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_human_has_github_id
        CHECK (role = 'baseline' OR github_id IS NOT NULL)
);

-- --------------------------------------------------------------------- models

-- One row per submission. Everything from commit_sha down is null at insert -- a submission names
-- a GitHub release and cannot state its own size, class or hashes. Admission fills them and moves
-- the row 'testing' -> 'verified'; promotion to 'active' is count's, after the trial match.
CREATE TABLE models (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        uuid         NOT NULL REFERENCES users (id),
    game_id         uuid         NOT NULL REFERENCES games (id),

    -- Stamped from the game's open season at submission, or by the season create for a carried
    -- baseline; never changed. A closed season's `active` versions are its final standing, which
    -- is why the one-active and release-uniqueness rules below are per season.
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

    -- The adapter's exact text, stored rather than referenced: it is small, it is what the
    -- evaluator runs, and holding the bytes means a re-validation sweep needs no network.
    adapter          text,

    -- Which evaluator build verified this version; a change in it is what makes a sweep necessary.
    evaluator_digest text,

    reject_reason   text,

    -- THE ADMISSION CLAIM. One row per item, so this per-row claim is the mutual exclusion -- a run
    -- that dies mid-batch releases what it never reached at once, and the row it held after
    -- admit_timeout_s. The verdict re-checks admit_token, so a lapsed claim writes nothing.
    -- admit_attempts counts REAL attempts: a loader-class fault decrements it, because an outage
    -- must not consume a competitor's three tries.
    admit_started_at timestamptz,
    admit_token      uuid,
    admit_attempts   int          NOT NULL DEFAULT 0,

    created_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT models_weight_class_not_open
        CHECK (weight_class <> 'open'),

    CONSTRAINT models_version_positive
        CHECK (version >= 1),

    -- Past 'testing' a row must know what it is: pair joins on status and would otherwise seat a
    -- null weights_hash.
    CONSTRAINT models_past_testing_has_contents
        CHECK (status IN ('testing', 'rejected')
            OR (weights_hash IS NOT NULL AND adapter_hash IS NOT NULL
                AND evaluator_digest IS NOT NULL AND weight_class IS NOT NULL)),

    CONSTRAINT models_adapter_matches_hash
        CHECK (adapter IS NULL
            OR adapter_hash = 'sha256:' || encode(sha256(convert_to(adapter, 'UTF8')), 'hex'))
);

-- -------------------------------------------------------------------- ratings

-- Two rows per promoted model: its weight class, and open. Created at promotion, so a testing,
-- verified or rejected model has none.
--
-- seed_mu / seed_sigma record what this version inherited from the one it replaced, at the instant
-- it was promoted. They are not derivable: the predecessor keeps rating on matches already in
-- flight, so its final mu is not the number its successor started from.
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

-- A match is born 'pending' by pair with everything needed to play it and nothing about how it
-- went. The row is the unit of work AND the unit of idempotence: `claim_token` is what makes a
-- stale replica's finish a no-op, `rated_seq` what makes a second fold impossible.
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

    -- The status and the columns that go with it cannot disagree. This is also half of what
    -- confines Kalam: with UPDATE granted on its own columns only, there is no state it can reach
    -- that is not one of its own -- it cannot mark a row 'rated', because it cannot write rated_at.
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

-- The order count folded matches in. A sequence rather than a timestamp: two matches can share a
-- played_at to the microsecond, and the audit needs a total order.
CREATE SEQUENCE rating_seq AS bigint;

-- ---------------------------------------------------------------- match_seats

-- One row per seat, not arrays and not one jsonb document: an array cannot be foreign-keyed, so a
-- seat could name a model that does not exist or one from another game. It is also what makes
-- "every match this version played" an index scan.
--
-- seat IS the index: seat 0 is the first player, the addressing ants/docs/protocol.md uses.
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
--
-- The primary key IS the correctness argument: (model_id, ladder, seq) with seq taken from
-- ratings.matches_played means a second fold of the same match collides rather than
-- double-counting, and the chain -- every event starting where the previous one ended -- is then
-- checkable by a join.
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

-- One table, two flavours of fence:
--
--   run fence   -- (scheduled_for, attempt). A cron run claims it at its first task with its own
--                  occurrence's identity, monotonically; every ladder write in the run then reads
--                  the row FOR SHARE and writes nothing if it has moved. Used by `count`.
--   epoch fence -- a counter any roster writer bumps. Pair reads it at run start and every insert
--                  checks it FOR SHARE, so a pairing decided against a roster that has since
--                  changed cannot land. Used by `roster`.
--
-- `pair` and `withdraw` are seeded as run fences nothing currently claims: pair's guarantee is the
-- roster epoch, and withdraw's single statement is idempotent. The rows cost nothing.
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

-- At most one submission in flight, spanning both pre-active states: a competitor with a verified
-- version waiting for its trial may not submit another.
CREATE UNIQUE INDEX models_one_in_flight_uniq
    ON models (owner_id, game_id) WHERE status IN ('testing', 'verified');

-- the same release cannot be entered twice IN ONE SEASON; it may be entered again in the next
CREATE UNIQUE INDEX models_owner_game_release_uniq
    ON models (owner_id, game_id, season_id, repo, release_tag);

-- The admission claim: testing rows, oldest first. Deliberately WITHOUT admit_started_at -- a
-- claim rewrites that column on every row it takes, and keeping it out leaves those updates
-- heap-only.
CREATE INDEX models_admit_claim_idx
    ON models (created_at) WHERE status = 'testing';

-- class ladders, by season; the season_id prefix also serves the open ladder
CREATE INDEX models_season_class_active_idx
    ON models (season_id, weight_class)
    WHERE status = 'active';

-- At most one contesting version per season -- as a DEFERRABLE exclusion constraint rather than a
-- partial unique index, so promotion's single statement does not depend on CTE order: Postgres
-- does not order the updates of sibling CTEs, and checked at commit both orders succeed. A closed
-- season's final version stays `active` (it is the standing) while the same owner contests the next.
ALTER TABLE models
    ADD CONSTRAINT models_one_active_excl
        EXCLUDE USING btree (owner_id WITH =, game_id WITH =, season_id WITH =)
        WHERE (status = 'active')
        DEFERRABLE INITIALLY DEFERRED;

-- matches -------------------------------------------------------------------

-- the claim: pending rows of one engine, oldest first
CREATE INDEX matches_pending_claim_idx
    ON matches (engine_digest, created_at) WHERE status = 'pending';

-- The in-flight set. Deliberately WITHOUT lease_expires_at: a renew every N turns rewrites that
-- column on every live row, and keeping it out is what leaves those updates heap-only. The reaper
-- scans this index and filters.
CREATE INDEX matches_in_flight_idx
    ON matches (claim_token) WHERE status IN ('claimed', 'running');

-- count's batch: finished, in finish order
CREATE INDEX matches_finished_idx
    ON matches (played_at, id) WHERE status = 'finished';

-- The public match listing, and the `matches_played` count a season carries (which reads the
-- season_id prefix alone). The trailing id makes the keyset cursor total: two matches can share a
-- played_at to the microsecond, and a page boundary that is not total repeats or skips a row.
CREATE INDEX matches_season_played_idx
    ON matches (season_id, played_at DESC, id DESC)
    WHERE status IN ('finished', 'rated');

-- One live trial per candidate. 'finished' is inside the predicate on purpose: a trial played but
-- not yet decided still counts as live, so pair cannot insert a second one in the window between
-- Kalam finishing it and count deciding it.
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

-- ------------------------------------------------------ one definition of each shape

-- The functions below exist because their shapes are returned by several routes each, and a shape
-- many routes build is a shape one of them will eventually get wrong on its own. Between them they
-- are the whole of what the API says about a season, a rank, a version's phase and a seat.

-- The four states, derived from three timestamps rather than stored, so no route can invent a fifth.
CREATE FUNCTION season_state(s seasons) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN s.closed_at IS NOT NULL        THEN 'closed'
                WHEN now() < s.submissions_open_at  THEN 'scheduled'
                WHEN now() < s.submissions_close_at THEN 'open'
                ELSE                                     'settling' END;
$$;

-- The season a game is currently read through: the live one, else the latest closed. Six routes
-- resolve a season this way and a seventh does with `?season=N` (p_number), which is the same
-- selection with the number pinned.
CREATE FUNCTION current_season(p_game uuid, p_number int DEFAULT NULL)
RETURNS SETOF seasons LANGUAGE sql STABLE AS $$
    SELECT * FROM seasons s
     WHERE s.game_id = p_game AND (p_number IS NULL OR s.number = p_number)
     ORDER BY (s.closed_at IS NULL) DESC, s.number DESC
     LIMIT 1;
$$;

-- The season object every route returns. The counts are the ones the site prints, and they are
-- different questions: `active_versions` is the ladder's size, `entered_versions` everything ever
-- submitted, `in_flight_versions` what "18 versions are mid-trial" means. `matches_played`
-- EXCLUDES TRIALS so it agrees with what GET /v1/matches can reach.
CREATE FUNCTION season_json(s seasons) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'number', s.number,
        'state',  season_state(s),
        'submissions_open_at',  s.submissions_open_at,
        'submissions_close_at', s.submissions_close_at,
        'closed_at',            s.closed_at,
        'close_requested_at',   s.close_requested_at,
        'engine_digest',        s.engine_digest,
        'rules',                s.rules,
        -- The caps this season is played under: they are per season, and a standing cannot be read
        -- without them.
        'weight_classes',       s.weight_classes,
        'active_versions',    (SELECT count(*) FROM models m
                               WHERE m.season_id = s.id AND m.status = 'active'),
        'entered_versions',   (SELECT count(*) FROM models m
                               WHERE m.season_id = s.id),
        'matches_played',     (SELECT count(*) FROM matches mt
                               WHERE mt.season_id = s.id AND mt.status IN ('finished', 'rated')
                                 AND mt.trial_model_id IS NULL),
        'in_flight_versions', (SELECT count(*) FROM models m
                               WHERE m.season_id = s.id AND m.status IN ('testing', 'verified')));
$$;

-- The two season rules, as predicates. Each is asked TWICE per submission -- once by the insert
-- that must not happen and once by the read that says why it did not -- and the two answers have
-- to be the same answer, or a competitor is refused for a reason the response denies.
CREATE FUNCTION season_admits(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'participants' ->> 'enabled')::bool, false)
        OR (p_user)::text IN (SELECT jsonb_array_elements_text(s.rules -> 'participants' -> 'user_ids'));
$$;

-- No OTHER competitor already holds these weights, within the rule's scope. A competitor may
-- always resubmit their own, and a rejected row does not hold a hash.
CREATE FUNCTION season_admits_weights(s seasons, p_user uuid, p_hash text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'unique_weights' ->> 'enabled')::bool, false)
        OR NOT EXISTS (SELECT 1 FROM models o
                        WHERE o.game_id = s.game_id AND o.weights_hash = p_hash
                          AND o.owner_id <> p_user AND o.status <> 'rejected'
                          AND (coalesce(s.rules -> 'unique_weights' ->> 'scope', 'game') = 'game'
                            OR o.season_id = s.id));
$$;

-- Which of the two clocks a version is waiting on, in the words the pages print. Four routes say
-- this; a version whose row is 'testing' or 'verified' yields the first three states only.
CREATE FUNCTION model_phase(m models) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN m.status = 'testing' AND m.admit_started_at IS NULL THEN 'queued'
                WHEN m.status = 'testing'   THEN 'verifying'
                WHEN m.status = 'verified'  THEN 'awaiting_trial'
                WHEN m.status = 'active'    THEN 'on_the_ladder'
                WHEN m.status = 'rejected'  THEN 'rejected'
                ELSE                             'superseded' END;
$$;

-- A rating is half a sentence; the Version screen, the profile and the caller's own list all print
-- "rank 6 of 47" beside it. THE ORDER IS THE LEADERBOARD'S -- conservative DESC, id -- and the id
-- tiebreak is not decoration: two ratings can be equal to the last bit, and without it a version's
-- own page and the ladder it appears on would disagree about which of the pair is fifth.
--
-- The field is the season's CURRENT field, since only `active` versions are on a ladder. A
-- superseded version keeps its ratings rows and gets a rank too: where it would place among the
-- versions playing now.
CREATE FUNCTION model_ratings(p_model uuid, p_settled_sigma float8)
RETURNS json LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_object_agg(r.ladder, json_build_object(
        'rating',      r.conservative,
        'mu',          r.mu,
        'sigma',       r.sigma,
        'provisional', r.sigma > p_settled_sigma,
        'matches',     r.matches_played,
        'rank',  (SELECT count(*) + 1
                  FROM models om JOIN ratings orr ON orr.model_id = om.id AND orr.ladder = r.ladder
                  WHERE om.season_id = m.season_id AND om.status = 'active'
                    AND (r.ladder = 'open' OR om.weight_class = r.ladder)
                    AND (orr.conservative > r.conservative
                     OR (orr.conservative = r.conservative AND om.id < m.id))),
        -- The model itself counts, whether or not it is still active. Without the second term a
        -- superseded version reads "rank 6 of 5": it is ranked against the live field but was not
        -- one of it. Dropped into the five playing now, it would be sixth of six.
        'field', (SELECT count(*) + (CASE WHEN m.status = 'active' THEN 0 ELSE 1 END)
                  FROM models om JOIN ratings orr ON orr.model_id = om.id AND orr.ladder = r.ladder
                  WHERE om.season_id = m.season_id AND om.status = 'active'
                    AND (r.ladder = 'open' OR om.weight_class = r.ladder))
    )), '{}'::json)
    FROM ratings r JOIN models m ON m.id = r.model_id
    WHERE r.model_id = p_model;
$$;

-- A match's seats, resolved: who sat there, in which class, and how it went for them. The three
-- match routes each return their own SHAPE -- the public listing, the caller's own and the match
-- page name different keys -- but the seat itself is one thing, and `outcome` is why this is a
-- function: a forfeited seat is `dq` and a beaten one is `loss`, and telling them apart needs the
-- strike limit, which is Jodi's forfeit_strikes and reaches SQL as a parameter.
CREATE FUNCTION match_seat_rows(p_match uuid, p_strike_limit int)
RETURNS TABLE (seat smallint, model_id uuid, owner text, owner_id uuid, baseline boolean,
               class ladder, version int, rank smallint, score int, strikes smallint, outcome text)
LANGUAGE sql STABLE AS $$
    SELECT s.seat, s.model_id, u.handle, md.owner_id, u.role = 'baseline',
           md.weight_class, md.version, s.rank, s.score, s.strikes,
           CASE WHEN s.rank IS NULL                    THEN NULL
                WHEN s.strikes >= p_strike_limit       THEN 'dq'
                WHEN s.rank > 1                        THEN 'loss'
                WHEN (SELECT count(*) FROM match_seats w
                       WHERE w.match_id = s.match_id AND w.rank = 1) > 1 THEN 'draw'
                ELSE                                        'win' END
      FROM match_seats s
      LEFT JOIN models md ON md.id = s.model_id
      LEFT JOIN users u   ON u.id = md.owner_id
     WHERE s.match_id = p_match
     ORDER BY s.seat;
$$;

-- ---------------------------------------------------------------- table storage

-- Every match row is updated at least four times after insert -- claim, start, renew (repeatedly),
-- finish, rate -- and the renews are the reason for the headroom: 30% free gives those updates
-- somewhere on the same page to go, which keeps them heap-only and off the indexes.
ALTER TABLE matches SET (fillfactor = 70);

-- ------------------------------------------------------------------ the roles

-- Confine each writer by grant rather than by convention. No password is set: the credential is
-- deployment configuration and lives in devops/, so the committed migration ships no secret, and
-- until one is set neither role can log in. Roles are cluster-global while this schema is
-- per-database, which is why each create is guarded.

-- Kalam plays matches. It can read the two tables it plays from and write only the columns it
-- reports, so "Kalam writes no rating" is a fact of the grant: it cannot rate a match, cancel one,
-- pair one, or touch models, ratings, users or clocks at all.
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

-- Jodi runs the version life cycle. The verbs are DERIVED from jodi/workflows/*.json, and
-- jodi/scripts/check-sql.sh re-derives them on every run, so a new statement needing a grant it
-- does not have fails there rather than at 3am. Two absences are the point of the exercise: no
-- DELETE anywhere, and nothing on `sessions` -- that is Soma's auth surface. rating_events is
-- INSERT-only because Jodi appends the audit trail and never reads it back.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jodi') THEN
        CREATE ROLE jodi LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO jodi;
GRANT SELECT ON clocks, games, matches, match_seats, models, ratings, seasons, users TO jodi;
GRANT INSERT ON matches, match_seats, rating_events, ratings TO jodi;
GRANT UPDATE ON clocks, matches, models, ratings, seasons TO jodi;
-- `nextval` needs the sequence as well as the table: count stamps every match it folds with
-- rated_seq, so without this the fold fails on the FIRST finished match -- and because `finished`
-- counts as in-flight when pair measures demand, the whole ladder then stops behind it.
GRANT USAGE ON SEQUENCE rating_seq TO jodi;

COMMIT;
