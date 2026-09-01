-- Soma M0 — initial schema
-- Transcribed from schema.md. Postgres 13+ (gen_random_uuid is built in).
--
-- Two services write this database:
--   Soma          — users, and the INSERT of a models row
--   game manager  — matches, ratings, and the admission columns + status on models
--
-- Neither is trusted to enforce "one active version" or "one submission in flight".
-- The partial unique indexes at the bottom are.

BEGIN;

-- ---------------------------------------------------------------- enumerations

CREATE TYPE user_role AS ENUM ('competitor', 'admin', 'baseline');

-- 'open' is a ladder, not a weight class: every model competes in its own class
-- and in open. models.weight_class is CHECKed against it below.
CREATE TYPE ladder AS ENUM ('nano', 'micro', 'mini', 'small', 'large', 'open');

CREATE TYPE model_status AS ENUM ('testing', 'active', 'superseded', 'rejected');

-- ---------------------------------------------------------------------- games

-- Also the fleet table: one game, one server.
CREATE TABLE games (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

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

-- One row per submission. Everything from commit_sha down is null at insert:
-- a submission names a GitHub release and cannot state its own size, class or
-- hashes. The game manager fills them at admission.
CREATE TABLE models (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        uuid         NOT NULL REFERENCES users (id),
    game_id         uuid         NOT NULL REFERENCES games (id),
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
    reject_reason   text,
    created_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT models_weight_class_not_open
        CHECK (weight_class <> 'open'),

    CONSTRAINT models_version_positive
        CHECK (version >= 1)
);

-- -------------------------------------------------------------------- ratings

-- Two rows per promoted model: its weight class, and open.
-- Created at promotion, so a testing or rejected model has none.
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

-- Seat arrays are positionally aligned: index IS seat number, the same
-- addressing docs/PROTOCOL.md uses for actions against ants.
--
-- Postgres cannot foreign-key an array element, so nothing here stops a match
-- referencing a model that does not exist or one from another game. The writer
-- must check both.
CREATE TABLE matches (
    id              uuid        PRIMARY KEY,   -- supplied by the writer, for idempotency
    game_id         uuid        NOT NULL REFERENCES games (id),

    cartridge_hash  text        NOT NULL,      -- what actually ran; with seed + preset,
    seed            bigint      NOT NULL,      -- the reproducibility triple
    preset          text        NOT NULL,
    reason          text        NOT NULL,      -- free text, never an enum: game-defined

    model_ids       uuid[]      NOT NULL,
    ranks           smallint[]  NOT NULL,      -- 1 = best; ties allowed
    scores          int[]       NOT NULL,      -- integer by law: game state carries no floats

    replay_key      text,
    played_at       timestamptz NOT NULL,      -- reported by the game server
    ingested_at     timestamptz NOT NULL DEFAULT now(),  -- our clock; orders any recompute

    CONSTRAINT matches_seats_aligned
        CHECK (cardinality(model_ids) = cardinality(ranks)
           AND cardinality(ranks)     = cardinality(scores)),

    CONSTRAINT matches_has_seats
        CHECK (cardinality(model_ids) >= 2)
);

-- -------------------------------------------------------------------- indexes

-- Seven. Four serve an endpoint, three enforce a rule.
-- games (slug) and ratings (model_id, ladder) are already covered by the
-- UNIQUE and PRIMARY KEY above.

-- versions are unambiguous per entry
CREATE UNIQUE INDEX models_owner_game_version_uniq
    ON models (owner_id, game_id, version);

-- at most one contesting version
CREATE UNIQUE INDEX models_one_active_uniq
    ON models (owner_id, game_id)
    WHERE status = 'active';

-- at most one submission in flight
CREATE UNIQUE INDEX models_one_testing_uniq
    ON models (owner_id, game_id)
    WHERE status = 'testing';

-- the same release cannot be entered twice
CREATE UNIQUE INDEX models_owner_game_release_uniq
    ON models (owner_id, game_id, repo, release_tag);

-- class ladders; the game_id prefix also serves the open ladder
CREATE INDEX models_game_class_active_idx
    ON models (game_id, weight_class)
    WHERE status = 'active';

-- GET /matches?model={id} — containment, not a join
CREATE INDEX matches_model_ids_gin
    ON matches USING gin (model_ids);

-- There is deliberately no index on ratings.conservative. Only active models are
-- ranked, status lives on models, and Postgres cannot build a partial index across
-- a join -- so it would be walked past every superseded and rejected version. The
-- leaderboard is a join filtered by models_game_class_active_idx, sorted afterward.
-- At M0 that sorts one row per competitor per ladder.

COMMIT;
