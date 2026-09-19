-- Soma -- the platform schema. One initial file rather than a migration chain: nothing is
-- released, so 0001 is rewritten in place until it is. Postgres 13+.
--
-- Three roles write this database (grants at the bottom of the file):
--   soma         -- the owner. The routes (users, sessions, an entry and a version) and the clocks
--                   (the version life cycle: matches, match_seats, ratings, rating_events, clocks).
--   kalam        -- the match player. SELECT on two tables, UPDATE on the columns it reports.
--   runner_gate  -- the eight runner routes: kalam's columns plus runner identity.
-- Nothing above is trusted to enforce one-active-version, one-submission-in-flight or
-- one-live-trial. The partial unique indexes and the exclusion constraint are.
--
-- AN ENTRY AND A VERSION ARE TWO TABLES. `models` is the entry -- a competitor's named model, keyed
-- by that name under its owner -- and `model_versions` is one submission of it.
-- Everything a rating, a seat or a match points at is a VERSION; everything a rename, a retirement
-- or a quota is about is an ENTRY. Before the split the two were one row and `(owner_id, game_id)`
-- was the entry's only name, which is why a competitor could hold exactly one.
--
-- Design: docs/schema.md. Verified against Postgres 16 by scripts/verify/run.sh.

BEGIN;

-- ---------------------------------------------------------------- enumerations

CREATE TYPE user_role AS ENUM ('competitor', 'admin', 'baseline');

-- 'open' is a ladder, not a weight class: every model competes in its own class and in open.
CREATE TYPE ladder AS ENUM ('nano', 'micro', 'mini', 'small', 'large', 'open');

-- 'verified' sits between 'testing' and 'active': admission has passed and the version is waiting
-- for its trial match. A status of its own so pair, count and withdraw can each test it alone.
--
-- 'disabled' is A BASELINE'S ALONE (N29): admitted, and out of play until an admin enables it, or
-- taken out of play since. It is not 'verified' because a baseline has no trial -- it is what a
-- trial is played against -- and not 'superseded' because nothing replaced it. Every reader that
-- asks for 'active' leaves it out, which is the point: off the ladder, unpaired, and a pending
-- match seating it is withdrawn. Its ratings and its matches stay, and enabling it again puts it
-- back where it was. Only admission's verdict and the baseline enable/disable route write it.
CREATE TYPE model_status AS ENUM ('testing', 'verified', 'active', 'disabled', 'superseded', 'rejected');

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
    -- `manifest` is its declaration (abi, game, basic boards, limits, budgets), `reference_observations`
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

-- ------------------------------------------------------- the season rules document

-- WHAT A SEASON'S RULES DOCUMENT MAY SAY: one row per key, and the reason every predicate further
-- down can read `rules` with a plain `->>` and a cast without a defensive coalesce around the
-- shape. A document that reached the column is a document of this shape.
--
-- Nine blocks, each with its own `enabled`, so a rule is turned on or off per season without a
-- schema change -- and so one season can be a nano-only cohort and the next an open field with no
-- code between them. EVERY block now defaults OFF: a season silent about a rule does not play it.
-- The tenth was `repo`, the lone default-true block, and it was the anti-impersonation guard for a
-- field that limited nothing -- so removing the field removed the exception with it.
--
-- A VALUES list and not a table: a CHECK constraint that reads a table is a constraint whose truth
-- depends on rows a restore may not have loaded yet. This list IS the documentation of the rules
-- document, and season_rules_ok() below is only the walker over it -- so a rule that is not in this
-- table does not exist, and one that is cannot be misspelt into silence.
CREATE FUNCTION season_rule_spec()
RETURNS TABLE (block text, key text, kind text, lo float8, hi float8, allowed text[])
LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES
    -- ---- entries: how many models and versions a competitor may hold. Asked by the entry create
    --      and by the submission insert, and by the reads that say why either did not happen.
      ('entries', 'enabled',                'bool', NULL::float8, NULL::float8, NULL::text[]),
      ('entries', 'max_per_user',           'int',      1,    1000, NULL),
      ('entries', 'max_per_class',          'int',      1,    1000, NULL),
      ('entries', 'in_flight_max',          'int',      1,     100, NULL),
      ('entries', 'versions_max_per_model', 'int',      1,   10000, NULL),
      ('entries', 'versions_max_per_user',  'int',      1,   10000, NULL),
      ('entries', 'cooldown_s',             'int',      0, 2592000, NULL),
    -- ---- unique_weights: no two entries stand on one set of weights, within the scope.
      ('unique_weights', 'enabled', 'bool', NULL, NULL, NULL),
      ('unique_weights', 'scope',   'enum', NULL, NULL, ARRAY['game', 'season', 'user']),
    -- ---- participants: a cohort season. Either list admits, and `handles` is resolved AT THE TIME
    --      OF ASKING -- a cohort is a list of GitHub logins written before the term starts, and
    --      resolving it once would silently refuse every member who signed in afterwards.
      ('participants', 'enabled',  'bool',  NULL, NULL, NULL),
      ('participants', 'handles',  'strs',  NULL, NULL, NULL),
      ('participants', 'user_ids', 'uuids', NULL, NULL, NULL),
    -- ---- classes: which of the season's weight classes may be entered. NARROWS weight_classes and
    --      never redefines it: that column stays the only definition of the class table, because
    --      its ascending CHECK is what makes admission's `ORDER BY max_bytes LIMIT 1` correct.
    --      Asked by ADMISSION and by nothing else -- a submission cannot state its class.
      ('classes', 'enabled', 'bool',    NULL, NULL, NULL),
      ('classes', 'allow',   'ladders', NULL, NULL, NULL),
    -- ---- graph: the ONNX surface a submission may use. Asked by admission's judge.
      ('graph', 'enabled',         'bool', NULL, NULL, NULL),
      ('graph', 'opset_min',       'int',     1,    30, NULL),
      ('graph', 'opset_max',       'int',     1,    30, NULL),
      ('graph', 'op_allowlist',    'strs', NULL, NULL, NULL),
      ('graph', 'params_max',      'int',     1, 1e12, NULL),
      ('graph', 'adapter_ops_max', 'int',     1,  1e9, NULL),
      -- `graph.dtypes` -- a quantised-only season, by the element types the WEIGHTS are stored in
      -- -- was removed on 15 September 2026 and is NOT a gap to fill back in casually. It read the
      -- initializers' declared types off the loader's own inspection, and the loader is gone: what
      -- a node reports at admission is `stats`, which carries parameters, nodes, operators,
      -- ir_version and opset and says nothing about how a weight is stored. The admit clock
      -- selected the rule and no verdict ever tested it, so a season declaring 'int8' was refusing
      -- nothing. Restoring it means a number Orion measures, not a column here.
      -- Advisory by default and null in every season the platform ships. Decision 46 removed the
      -- compute cap on measurement: wall clock belongs to the admission host, so a verdict turning
      -- on it depends on a noisy neighbour and a re-run can flip it. A season that sets this is
      -- choosing load-dependent admission, deliberately.
      ('graph', 'infer_us_max',    'int',     1,  1e9, NULL),
      ('graph', 'size_metric',     'enum', NULL, NULL, ARRAY['zstd19', 'raw']),
    -- ---- execution: THE TERMS A MODEL COMPETES UNDER, sent to a runner on the claim.
    --      A speed season is `{"execution": {"enabled": true, "turn_ms": 250}}` and nothing else.
    --
    --      These were [vars] on every Kalam replica until the runner gate, and the reason is a
    --      GRANT: the `kalam` role has no privilege on `seasons`, so the process that needed them
    --      could not read the table they belong in. That is also why matches.strike_ceiling is
    --      pinned per row (decision 54) rather than read here. The gate assembles the claim at the
    --      centre, where `matches -> seasons` is one join it already has, so a value no longer has
    --      to be copied onto a match row to reach the process that plays it.
    --
    --      READ `coalesce(rule, games.manifest -> 'limits', [vars])`: a season that declares
    --      nothing plays by the cartridge's own published limits, which is where turn_ms and
    --      max_turns have always really lived. refusal_ceiling has no manifest key -- the cartridge
    --      has no opinion about how often a NODE may refuse a row -- so it falls straight to the var.
    --
    --      NOT PINNED ONTO THE MATCH ROW, and it does not need to be: `rules` is immutable once
    --      submissions open, which is the same property that lets count read a season's rating
    --      constants at fold time. A queued match therefore cannot have its terms changed under it.
      ('execution', 'enabled',         'bool', NULL,  NULL, NULL),
      -- How long a model has to answer one turn. THE constraint that decides how large a model can
      -- be and still play, so it is the one number a season changes to change the contest.
      ('execution', 'turn_ms',         'int',     1, 60000, NULL),
      -- Match length: the strategy horizon, and the compute a match costs.
      ('execution', 'max_turns',       'int',     1, 100000, NULL),
      -- How often a row may be refused for want of a model before it fails MODEL_UNAVAILABLE.
      -- The operational sibling of pairing.forfeit_strikes.
      ('execution', 'refusal_ceiling', 'int',     1,   100, NULL),
    -- ---- pairing: what the ladder asks for. Read by pair, and by count's verdict.
    --      Which BOARDS it is played on is not a rule (N28): it is season_maps, the one part of a
    --      season an admin may change while it is live. `pairing.presets` went with the presets.
      ('pairing', 'enabled',              'bool',    NULL, NULL, NULL),
      ('pairing', 'self_pairing',         'bool',    NULL, NULL, NULL),
      ('pairing', 'queue_share_max',      'int',        1, 1000, NULL),
      ('pairing', 'cross_class_fraction', 'num',        0,    1, NULL),
      ('pairing', 'burst',                'int',        0, 1000, NULL),
      ('pairing', 'steady_cap',           'int',        0, 1000, NULL),
      -- One key where the deploy has two names for one number: `repair_cap` is both count's
      -- UNPLAYABLE ceiling and pair's re-pair cap, and they have never been allowed to differ.
      ('pairing', 'trials_max',           'int',        1,  100, NULL),
      ('pairing', 'forfeit_strikes',      'int',        1, 1000, NULL),
    -- ---- rating: TrueSkill's parameters, and what "settled" means.
      ('rating', 'enabled',          'bool', NULL, NULL, NULL),
      ('rating', 'prior_mu',         'num',     0, 1000, NULL),
      ('rating', 'prior_sigma',      'num',  1e-9, 1000, NULL),
      ('rating', 'beta',             'num',  1e-9, 1000, NULL),
      ('rating', 'tau',              'num',     0, 1000, NULL),
      ('rating', 'draw_probability', 'num',     0,    1, NULL),
      ('rating', 'sigma_inflation',  'num',     1,  100, NULL),
      ('rating', 'settled_sigma',    'num',  1e-9, 1000, NULL),
    -- ---- standings: how the ladder is read. `ranked_per_user_max` is work the entry split makes
    --      necessary: one active version per ENTRY per season means one competitor with five
    --      entries holds five ladder rows, which without a cap is a top ten of one name.
      ('standings', 'enabled',             'bool', NULL, NULL, NULL),
      ('standings', 'basis',               'enum', NULL, NULL,
                                            ARRAY['best_version', 'best_per_class', 'top_k_sum']),
      ('standings', 'k',                   'int',     1,  100, NULL),
      ('standings', 'ranked_per_user_max', 'int',     1, 1000, NULL),
      ('standings', 'headline',            'enum', NULL, NULL,
                                            ARRAY['nano','micro','mini','small','large','open']),
      ('standings', 'lambda',              'num',     0, 1000, NULL),
      ('standings', 'visibility',          'enum', NULL, NULL, ARRAY['live', 'hidden_until_close']),
    -- ---- closure: when the season ends.
      ('closure', 'enabled',           'bool', NULL, NULL, NULL),
      ('closure', 'policy',            'enum', NULL, NULL, ARRAY['settle', 'deadline', 'admin']),
      ('closure', 'settle_grace_days', 'int',     0,  365, NULL)
    ) AS t (block, key, kind, lo, hi, allowed);
$$;

-- Refuses an unknown key AT BOTH LEVELS, and every value that is not of its declared kind inside
-- its declared range. Both halves are the point: the CHECK this replaces enumerated two block names
-- and looked no further, so `{"participants": {"enabld": true}}` stored cleanly and then admitted
-- the world -- the rule read as off through the coalesce every predicate uses, silently.
--
-- A block present without `enabled` is refused for the same reason: it is the one shape whose
-- failure is invisible at every later read.
CREATE FUNCTION season_rules_ok(r jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_typeof(r) = 'object'
       -- no block this schema does not name
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_object_keys(r) AS k
            WHERE k NOT IN (SELECT DISTINCT s.block FROM season_rule_spec() s))
       -- every block is an object, and every block carries `enabled`
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_each(r) AS b (block, doc)
            WHERE jsonb_typeof(b.doc) <> 'object'
               OR jsonb_typeof(b.doc -> 'enabled') IS DISTINCT FROM 'boolean')
       -- no key its block does not name
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_each(r) AS b (block, doc), jsonb_object_keys(b.doc) AS k
            WHERE NOT EXISTS (SELECT 1 FROM season_rule_spec() s
                               WHERE s.block = b.block AND s.key = k))
       -- and every value present is of its kind, in its range
       AND NOT EXISTS (
           SELECT 1
             FROM jsonb_each(r) AS b (block, doc)
             JOIN season_rule_spec() s ON s.block = b.block
            CROSS JOIN LATERAL (SELECT b.doc -> s.key AS v) x
            WHERE x.v IS NOT NULL AND jsonb_typeof(x.v) <> 'null'
              AND NOT CASE s.kind
                  WHEN 'bool' THEN jsonb_typeof(x.v) = 'boolean'
                  WHEN 'int'  THEN jsonb_typeof(x.v) = 'number'
                               AND (x.v #>> '{}')::numeric = trunc((x.v #>> '{}')::numeric)
                               AND (x.v #>> '{}')::float8 BETWEEN s.lo AND s.hi
                  WHEN 'num'  THEN jsonb_typeof(x.v) = 'number'
                               AND (x.v #>> '{}')::float8 BETWEEN s.lo AND s.hi
                  WHEN 'enum' THEN jsonb_typeof(x.v) = 'string'
                               AND (x.v #>> '{}') = ANY (s.allowed)
                  WHEN 'strs' THEN jsonb_typeof(x.v) = 'array'
                               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x.v) e
                                                WHERE jsonb_typeof(e) <> 'string'
                                                   OR btrim(e #>> '{}') = '')
                  -- a weight class, and never 'open': open is a ladder, not a class
                  WHEN 'ladders' THEN jsonb_typeof(x.v) = 'array'
                               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x.v) e
                                                WHERE jsonb_typeof(e) <> 'string'
                                                   OR (e #>> '{}') NOT IN
                                                      ('nano','micro','mini','small','large'))
                  -- resolved by season_admits() with a cast, so a string that is not a uuid would
                  -- be a 22P02 at read time -- on the submission path, as a 500
                  WHEN 'uuids' THEN jsonb_typeof(x.v) = 'array'
                               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x.v) e
                                                WHERE jsonb_typeof(e) <> 'string'
                                                   OR (e #>> '{}') !~*
                               '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                  END)
       -- one cross-key rule. An opset window that is not a window admits nothing --
       AND coalesce((r -> 'graph' ->> 'opset_min')::int, 0)
           <= coalesce((r -> 'graph' ->> 'opset_max')::int, 2147483647);
$$;

-- A season's slug, from its name: lower-cased, every run of anything but [a-z0-9] one hyphen, the
-- ends trimmed. "Summer 2026" is summer-2026 and "FireAnts 2026" fireants-2026. IMMUTABLE, so the
-- CHECK on seasons can hold every row to it; a name that leaves nothing ("🔥 🔥") gives '' and
-- fails seasons_slug_shape, which the create reads back as season_name_unusable.
CREATE FUNCTION season_slug(p_name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g'), '-');
$$;

-- A competition window for one game, created by an admin. A version belongs to exactly one season;
-- seasons of a game never overlap (the partial unique index below IS that rule) and the next opens
-- at least season_gap_days after the previous closed; a season closes when its scores have settled
-- or when an admin asks. Its standings -- its `active` versions and their ratings -- are kept for ever.
CREATE TABLE seasons (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid        NOT NULL REFERENCES games (id),

    -- AN INTERNAL ORDINAL, AND NO LONGER ANY KIND OF ADDRESS (N28): 1, 2, ... per game, read by the
    -- order seasons are listed in and by nothing a person types. Every URL, route parameter, query
    -- and notification names the slug. (It also found the season before this one, whose baselines
    -- a create used to carry forward; since N29 a season's baselines are uploaded to it.)
    number               int         NOT NULL,

    -- WHAT A PERSON CALLS IT, AND HOW EVERYTHING ELSE ADDRESSES IT. The admin names the season
    -- ("Summer 2026", "FireAnts 2026") and the slug is derived from the name by season_slug() --
    -- a CHECK, below, so no writer can store a slug that is not its name's. NEITHER EVER CHANGES:
    -- no route updates them, because a slug that moved would break every link already shared, and
    -- a name that moved would leave the slug naming something else.
    name                 text        NOT NULL,
    slug                 text        NOT NULL,

    engine_digest        text        NOT NULL,   -- pinned from games.active_engine_digest at creation

    submissions_open_at  timestamptz NOT NULL,
    submissions_close_at timestamptz NOT NULL,
    closed_at            timestamptz,                                -- set by the close, once

    -- An admin's request to close, consumed by withdraw's next tick. Stays set on the closed row
    -- as the record that the close was asked for rather than reached.
    close_requested_at   timestamptz,

    -- THE WHOLE DESCRIPTION OF THIS CONTEST. One document, each rule under its own block with an
    -- `enabled` flag; season_rule_spec() is what it may say and season_rules_ok() is the CHECK.
    -- Every rule that supersedes a [vars] value is read `coalesce(rule, var)`, so a season that
    -- declares nothing behaves exactly as the deploy does.
    --
    -- IMMUTABLE ONCE THE SEASON OPENS -- soma-seasons-update carries `now() < submissions_open_at`
    -- -- and that predicate is load-bearing far from here: it is what lets count read a season's
    -- rating constants at fold time instead of pinning them onto every match row.
    rules                jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- THE ONLY DEFINITION OF THE WEIGHT CLASSES, smallest first. Per season deliberately: a season
    -- can be focused (nano-only, or every cap a notch down) at the price of comparability across
    -- seasons, which is why every route returning a season returns these with it. `classes.allow`
    -- narrows this table for entry; it never adds to it.
    --
    -- RECALIBRATED 14 SEPTEMBER 2026, when the metric changed. `S` was zstd-19 over the graph's
    -- initializers plus the adapter; `S'` is `artifact_bytes + len(manifest)` -- raw, and measured
    -- against a digest the node re-hashes (decision R4). Raw bytes are roughly twice compressed
    -- ones for these artifacts, so every cap doubled: the table still means the parameter budget
    -- it always meant. PROVISIONAL, and the open question is whether a class should cap
    -- `stats.parameters` instead, which Orion 1.8.1 made honest enough to gate on.
    weight_classes       jsonb       NOT NULL DEFAULT
        '[{"class": "nano",  "max_bytes": 16384},
          {"class": "micro", "max_bytes": 131072},
          {"class": "mini",  "max_bytes": 1048576},
          {"class": "small", "max_bytes": 8388608},
          {"class": "large", "max_bytes": 134217728}]'::jsonb,

    created_at           timestamptz NOT NULL DEFAULT now(),

    UNIQUE (game_id, number),
    -- One slug a game, and so one name a game up to what the slug keeps: "Summer 2026" and
    -- "summer-2026" would be one URL. The create answers season_slug_taken rather than a 23505.
    UNIQUE (game_id, slug),
    -- Not a second key: the composite target model_versions pins its game to, so a version cannot
    -- belong to one game's entry and another game's season.
    UNIQUE (id, game_id),
    CONSTRAINT seasons_number_positive CHECK (number >= 1),
    CONSTRAINT seasons_name_shape      CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 48),
    -- The slug IS the name's, and never a word a route already uses as a segment.
    CONSTRAINT seasons_slug_derived    CHECK (slug = season_slug(name)),
    CONSTRAINT seasons_slug_shape      CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                                              AND char_length(slug) <= 48
                                              AND slug NOT IN ('current', 'live', 'latest', 'new')),
    CONSTRAINT seasons_window          CHECK (submissions_close_at > submissions_open_at),
    CONSTRAINT seasons_rules_shape     CHECK (season_rules_ok(rules)),
    CONSTRAINT seasons_weight_classes_shape CHECK (weight_classes_ok(weight_classes))
);

-- At most one live season per game. This IS the non-overlap rule, as an index.
CREATE UNIQUE INDEX seasons_one_live_uniq ON seasons (game_id) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------- users

-- Baselines are users -- one per reference opponent, so they can be told apart on a ladder that
-- displays a model as its owner's handle. They never sign in, hence the nullable github_id. An
-- admin makes one by uploading it into a season under a name (N29), and the account is
-- `baseline.<slug of that name>`: the same name in a later season is the same baseline again.
CREATE TABLE users (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- THE STABLE IDENTITY. GitHub guarantees an account id never changes and is never reused; the
    -- login below is neither of those things. It is the conflict key of the sign-in upsert, so it
    -- is the one thing recorded about a competitor that cannot go stale.
    github_id   bigint      UNIQUE,

    -- THE GITHUB LOGIN, not a nickname: soma-auth-github's upsert writes gh.login here on every
    -- sign-in, not just the first. It is therefore a CACHE OF A MUTABLE REMOTE VALUE -- a
    -- competitor who renames themselves on GitHub is renamed here at their next sign-in and not
    -- before -- so it is a label, and anything decided by it is decided on a value that may be a
    -- month old. github_id is what a decision about identity belongs on.
    --
    -- Uniqueness is on lower(handle), below, and not here. Every reader compares case-insensitively
    -- (season_admits and the profile route); a case-sensitive index and case-insensitive
    -- readers protect different namespaces, which is how `Alice` and `alice` could be two rows that
    -- both answer to one login.
    --
    -- TWO RESERVED PREFIXES, both containing a `.`, which a GitHub login cannot: `baseline.` for
    -- the uploaded reference opponents, and `released.` for a login taken back from a row that
    -- provably no longer holds it -- see soma-auth-github. A login is [A-Za-z0-9-] and cannot
    -- contain a dot, so neither prefix can be minted against us.
    handle      text        NOT NULL,

    -- Seeded from GitHub ON INSERT ONLY: overwriting it at every sign-in would silently undo the
    -- one field PATCH /v1/me lets a competitor edit. Null falls back to the handle.
    display_name text,

    role        user_role   NOT NULL DEFAULT 'competitor',
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_human_has_github_id
        CHECK (role = 'baseline' OR github_id IS NOT NULL),

    -- A baseline's handle lives in the reserved namespace and not in GitHub's. Without this a real
    -- account whose login happened to equal a baseline's handle -- `baseline-nano-bc` was one -- could
    -- never sign in at all: the upsert would collide on the handle index, unhandled, for ever.
    CONSTRAINT users_baseline_handle_reserved
        CHECK (role <> 'baseline' OR handle LIKE 'baseline.%')
);

-- Case-insensitive, because every reader is. It is also the conflict target of every
-- INSERT ... ON CONFLICT on this table, and must be spelled `ON CONFLICT (lower(handle))` -- an
-- expression index is only a valid arbiter in the exact form it was declared in.
CREATE UNIQUE INDEX users_handle_uniq ON users (lower(handle));

-- ------------------------------------------------------------------- runners

-- WHO PLAYS A MATCH IS NOW A ROW. A replica used to be a process holding the `kalam` Postgres role,
-- so "which machine played this" was answered by which container was up. A runner reaches the
-- platform over /v1/runner/* instead, from hardware that may be nowhere near the deployment, and
-- these two tables are the whole of its identity: a credential an admin holds, and a process that
-- presented it.

-- An admin's runner credential. A TABLE rather than a column on users, so an admin can hold two
-- keys and retire one without a gap -- rotation with no window in which nothing works.
--
-- HASHED, NOT STORED. `key_hash` is sha256 over the key the create route returned exactly once, so
-- this table cannot re-mint a credential and reading it is not the same as holding one. That is a
-- stronger property than the design first asked for -- it wanted the key visible in the admin UI --
-- and it costs one column: `key_prefix` is display material, enough to recognise a key in a list
-- and useless to present. The lookup stays a single indexed probe because the hash is
-- deterministic; a salted password hash would have forced a scan and then a verify.
CREATE TABLE runner_keys (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    -- The admin's own words: which key this is, so retiring the right one is possible.
    label        text        NOT NULL,

    key_hash     text        NOT NULL UNIQUE,   -- sha256 of the key, hex
    key_prefix   text        NOT NULL,          -- 'tbr_a1b2c3d4', the half that may be shown

    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,                   -- stamped at each token exchange
    revoked_at   timestamptz,

    CONSTRAINT runner_keys_label_shape
        CHECK (btrim(label) <> '' AND length(label) <= 64)
);

-- One row per running process. SELF-REGISTERED at token exchange on (key_id, label): an admin
-- enrols nothing, so "start a runner" is copy the key and run the image, and a second runner on the
-- same key is simply a second row. Removing the enrolment flow is the point -- there is no state a
-- human has to create before a machine can work.
CREATE TABLE runners (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    key_id        uuid        NOT NULL REFERENCES runner_keys (id) ON DELETE CASCADE,
    label         text        NOT NULL,          -- the host's own name, by default

    -- REPORTED AT TOKEN EXCHANGE, and they are facts about a runner rather than authority over one.
    -- Three values cannot ride the claim response the way turn_ms and max_turns do, because they
    -- are Orion instance config rather than workflow data: a node cannot be told its own
    -- ops_budget. So the runner says them and the gate checks what it can -- which is worth doing
    -- precisely because the operators are trusted: misconfiguration is what actually happens.
    engine_digest text,
    node_version  text,
    orion_version text,                          -- which Orion ran the adapters; a sweep is per upgrade
    ops_budget    bigint,
    arch          text,                          -- 'arm64' | 'amd64'; operational, never enforced

    -- How many rows this runner may hold at once. A wedged runner is not an attack -- the operator
    -- is an admin -- but it can sit on rows until their leases lapse, and one predicate on the
    -- claim makes that impossible. It is also how a beefier host is allowed sixteen lanes without
    -- editing a definition anywhere.
    max_in_flight smallint    NOT NULL DEFAULT 4,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at    timestamptz,

    CONSTRAINT runners_max_in_flight_positive CHECK (max_in_flight > 0),

    UNIQUE (key_id, label)
);

-- live_sessions' argument applied to runners, and it is the same argument: a revoked key, a revoked
-- runner, a deleted user OR AN ADMIN WHO IS NO LONGER ONE all end the runner's next call. Every
-- runner statement JOINs this rather than trusting the bearer token it arrived with, so a demotion
-- takes effect at once -- the rule Soma's admin routes already follow by reading `role` off the
-- live row instead of off a cookie claim. A JSONLogic guard would fail OPEN if it were ever wrong;
-- a JOIN cannot be forgotten.
CREATE VIEW live_runners AS
    SELECT r.id, r.key_id, r.label, r.max_in_flight, k.user_id
      FROM runners r
      JOIN runner_keys k ON k.id = r.key_id AND k.revoked_at IS NULL
      JOIN users u       ON u.id = k.user_id AND u.role = 'admin'
     WHERE r.revoked_at IS NULL;

-- The key half of the same predicate, and it exists for the same reason `live_runners` does: the
-- token exchange has to know that a key belongs to a LIVE ADMIN, and the role that runs the
-- exchange must not be able to read `users` to find out. A view is owned by the schema owner and
-- runs with its privileges, so the join happens without the caller ever holding SELECT on `users`.
--
-- Demotion takes effect at the next token exchange, and revocation at the next CALL -- `live_runners`
-- is what carries the second, and it is stricter on purpose: a token already minted is bounded by
-- its ten minutes, but a statement is fenced now.
CREATE VIEW live_runner_keys AS
    SELECT k.id, k.user_id, k.key_hash, k.key_prefix
      FROM runner_keys k
      JOIN users u ON u.id = k.user_id AND u.role = 'admin'
     WHERE k.revoked_at IS NULL;

-- --------------------------------------------------------------------- models

-- ONE ROW PER ENTRY, and AN ENTRY IS A NAME. A competitor makes one by naming it; from then on
-- every version they submit is a version OF this row. This id -- not a version's -- is what a
-- rename, a retirement and a quota are about, and it is also how the entry is ADDRESSED:
-- `GET /v1/models/{id}`, the same shape `/v1/matches/{id}` already uses.
--
-- The entry holds what does not change between submissions, and nothing a submission decides: the
-- name is here and `version` is on the version, and that division IS the split. Nothing is ever
-- deleted -- ratings, matches and the audit trail all reach this row through its versions -- so
-- `retired_at` is how a competitor puts one down.
CREATE TABLE models (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id    uuid        NOT NULL REFERENCES users (id),
    game_id     uuid        NOT NULL REFERENCES games (id),

    -- The competitor's own word for it, and what the site prints beside the handle when one
    -- competitor holds several. Unique per owner per game (below), and DISPLAY ONLY: an entry is
    -- addressed by its id, so this never has to survive a URL and keeps its free-text shape.
    name        text        NOT NULL,

    created_at  timestamptz NOT NULL DEFAULT now(),

    -- "No more versions here." Not a delete: every version keeps its ratings and its place in
    -- every match it played. A retired entry frees its slot under entries.max_per_user --
    -- retirement is not how a version history is restarted.
    retired_at  timestamptz,

    CONSTRAINT models_name_shape CHECK (btrim(name) <> '' AND length(name) <= 64),

    -- Not a second key: the composite target model_versions pins its game to.
    UNIQUE (id, game_id)
);

-- ONE ENTRY PER NAME PER OWNER, and since the repository left the submission path this is the ONLY
-- key an entry has -- which it already effectively was. It keeps the caller's own list readable and
-- stops a rename producing two rows a page has no way to tell apart.
--
-- THERE IS DELIBERATELY NO CROSS-COMPETITOR UNIQUENESS. Two competitors may both call an entry
-- `ants`: a name is not an identity, and nothing is decided on one. Who a competitor is, is
-- `users.github_id` -- sign-in, which is the whole of what GitHub does here now. The repository
-- that used to be the global key limited nothing (every ceiling is a season rule and none of them
-- mentioned it) and cost a normaliser, a season predicate, two indexes and an ownership call that
-- failed closed, so a rate-limited GitHub stopped anyone creating an entry at all.
--
-- NOT partial on retired_at: retiring an entry must not be how its version numbers restart.
CREATE UNIQUE INDEX models_owner_game_name_uniq
    ON models (owner_id, game_id, lower(name));

-- the caller's entries, and a public profile's
CREATE INDEX models_owner_idx ON models (owner_id, game_id);

-- ------------------------------------------------------------- model_versions

-- ONE ROW PER SUBMISSION: what `models` held before the entry was split out of it. Everything from
-- `status` down is null at insert -- a submission is two hashes and two uploads, and cannot state
-- its own size, class or timings. Admission fills them and moves the row 'testing' -> 'verified';
-- promotion to 'active' is count's, after the trial match.
--
-- EVERY RULE THAT WAS SCOPED (owner_id, game_id) IS SCOPED model_id HERE, and that is the change:
-- version numbers restart per entry, one submission is in flight per entry, one version is active
-- per entry per season. A per-USER ceiling on any of them is a cardinality over an owner's entries
-- and not a property of one row, so it is a season predicate and never an index.
CREATE TABLE model_versions (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id        uuid         NOT NULL,

    -- Carried from the entry and PROVED equal to it rather than trusted: with (model_id, game_id)
    -- and (season_id, game_id) both foreign-keyed, a version cannot belong to one game's entry and
    -- another game's season -- a disagreement the schema could not previously notice. It also earns
    -- its keep, since the admission batch, the demand read and the trial pick all want the game id.
    game_id         uuid         NOT NULL,

    -- Stamped from the game's open season at submission, or from the season an admin uploaded a
    -- baseline into; never changed. A closed season's `active` versions are its final standing,
    -- which is why the one-active rule below is per season.
    season_id       uuid         NOT NULL,

    -- THE ONLY LABEL A SUBMISSION HAS, and it is the platform's, not the competitor's: 1, 2, 3...
    -- per entry, assigned by the insert as `max(version) + 1`. It replaced `release_tag`, a string
    -- that named a GitHub release nothing ever verified -- so the label a competitor typed and the
    -- release it claimed to name could disagree with nobody noticing. A counter cannot.
    version         int          NOT NULL,

    status          model_status NOT NULL DEFAULT 'testing',

    weight_class    ladder,
    size_bytes      bigint,
    param_count     bigint,
    -- The slowest reference case's inference at admission, in microseconds. Reported to the
    -- competitor, and a gate only where a season deliberately makes it one (graph.infer_us_max,
    -- null everywhere the platform ships): there is no compute cap (decision 46) and wall clock
    -- belongs to the admission host, so a verdict turning on it depends on a noisy neighbour. It
    -- says how much of the game's turn_ms a graph leaves itself, which is the bound that decides
    -- whether a seat forfeits.
    infer_us        bigint,
    -- sha256 of the ONNX artifact, spelled `sha256:<hex>` -- the same string Orion's model
    -- registration carries and re-hashes the fetched object against, so the row and the node agree
    -- by construction rather than by trust.
    weights_hash    text,
    manifest_hash   text,

    -- The Orion model manifest, exactly as it was registered: `orion:model@1.0.0`, the inputs with
    -- their adapters, the outputs, `probe_dims`. Stored rather than referenced -- it is small, it
    -- is what the node runs, and holding the bytes means a re-validation sweep needs no network.
    -- Its length is the second term of the weight class (decision R4).
    manifest         text,

    -- Where the bytes live: the object key under the models bucket. GENERATED, never written --
    -- Soma mints a presigned PUT for exactly this key when the submission is accepted, the admit
    -- clock reads the object from it at admission, and every replica's roster clock fetches it
    -- from there by digest. Three readers, one spelling, and no statement that could disagree
    -- with another about where a version's bytes are.
    artifact_key     text GENERATED ALWAYS AS ('models/' || id::text || '/model.onnx') STORED,

    -- Which Orion served the verdict; a change in it is what makes a sweep necessary (R10). It
    -- replaces `evaluator_digest`, which named an axon build that no longer exists.
    orion_version    text,

    -- What the admission probe bound each named dimension to, as `{"H": 128, "W": 128}`. Without
    -- it `infer_us` is not comparable between two versions, because a variable axis means the
    -- number was measured at a size the manifest chose (R2).
    probe_dims       jsonb,

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

    FOREIGN KEY (model_id, game_id)  REFERENCES models  (id, game_id),
    FOREIGN KEY (season_id, game_id) REFERENCES seasons (id, game_id),

    CONSTRAINT model_versions_weight_class_not_open
        CHECK (weight_class <> 'open'),

    CONSTRAINT model_versions_version_positive
        CHECK (version >= 1),

    -- Past 'testing' a row must know what it is: pair joins on status and would otherwise seat a
    -- null weights_hash.
    CONSTRAINT model_versions_past_testing_has_contents
        CHECK (status IN ('testing', 'rejected')
            OR (weights_hash IS NOT NULL AND manifest_hash IS NOT NULL
                AND orion_version IS NOT NULL AND weight_class IS NOT NULL)),

    CONSTRAINT model_versions_manifest_matches_hash
        CHECK (manifest IS NULL
            OR manifest_hash = 'sha256:' || encode(sha256(convert_to(manifest, 'UTF8')), 'hex'))
);

-- -------------------------------------------------------------------- ratings

-- Two rows per promoted VERSION: its weight class, and open. Created at promotion, so a testing,
-- verified or rejected version has none.
--
-- seed_mu / seed_sigma record what this version inherited from the one it replaced, at the instant
-- it was promoted. They are not derivable: the predecessor keeps rating on matches already in
-- flight, so its final mu is not the number its successor started from.
CREATE TABLE ratings (
    version_id      uuid    NOT NULL REFERENCES model_versions (id) ON DELETE CASCADE,
    ladder          ladder  NOT NULL,

    mu              float8  NOT NULL,
    sigma           float8  NOT NULL,
    conservative    float8  GENERATED ALWAYS AS (mu - 3 * sigma) STORED,

    seed_mu         float8,
    seed_sigma      float8,

    matches_played  int         NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (version_id, ladder)
);

-- ---------------------------------------------------------------- season maps

-- THE BOARDS A SEASON IS PLAYED ON (N28). Uploaded one file at a time by an admin, stored DISABLED,
-- and played only once an admin enables them; enabled and disabled at will until the close, and
-- NEVER DELETED -- no route deletes one, and soma-db refuses a DELETE outright -- because the matches
-- played on a board name it, and the board is public from the moment its upload succeeds.
--
-- The one part of a season that may change while it is live. `rules` is immutable once submissions
-- open, and that stays true: which boards are in play is not a rule, and pair reads the enabled set
-- on every run. A queued match pins its board by id, so disabling one cannot change a match under
-- it; the disable cancels only the rows nobody has claimed.
--
-- THE HEADER IS THE PLATFORM'S AND THE BOARD IS THE CARTRIDGE'S. map_id, players, rows and cols
-- are read out of the file at upload and are all the platform ever reads; `board` is stored as sent
-- and only ever passed to worldgen, on the claim. Whether it is a board worth playing is the
-- ENGINE'S judgement, made at upload (Soma calls worldgen on it) and again at every enable.
CREATE TABLE season_maps (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    map_id      text        NOT NULL,     -- the file's `id`
    players     smallint    NOT NULL,
    rows        smallint    NOT NULL,
    cols        smallint    NOT NULL,
    -- sha256 of board::text -- Postgres's own canonical rendering of the jsonb, not the uploaded
    -- file's bytes, which a workflow never sees. Enough to refuse the same board uploaded twice.
    digest      text        NOT NULL,
    board       jsonb       NOT NULL,
    enabled     boolean     NOT NULL DEFAULT false,
    added_at    timestamptz NOT NULL DEFAULT now(),
    added_by    uuid        NOT NULL REFERENCES users (id),

    -- One id and one board a season, for ever. There is no delete, so a board taken out of play is
    -- disabled and later enabled again, never uploaded a second time.
    UNIQUE (season_id, map_id),
    UNIQUE (season_id, digest),
    CONSTRAINT season_maps_id_shape  CHECK (map_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                                            AND char_length(map_id) <= 64),
    -- THE MAP DECIDES THE SEAT COUNT, and a match needs two. The upper bound is not here: it is the
    -- cartridge's `limits.boards`, which the upload checks against the game row it can read.
    CONSTRAINT season_maps_players   CHECK (players >= 2),
    CONSTRAINT season_maps_sides     CHECK (rows >= 1 AND cols >= 1),
    CONSTRAINT season_maps_board     CHECK (jsonb_typeof(board) = 'object')
);

-- Every enable and disable, so "which boards were in play on 3 October" has an answer. Written in
-- the same statement as the flip; the upload writes none, because added_at is the upload and a
-- board uploaded and never enabled was never in play.
--
-- A surrogate key, not (season_map_id, at): two flips of one board inside one transaction -- which
-- the verify scenario does -- would share a now(), so `at` is clock_timestamp() and not the key.
CREATE TABLE season_map_events (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    season_map_id uuid        NOT NULL REFERENCES season_maps (id),
    at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    enabled       boolean     NOT NULL,
    by_user       uuid        NOT NULL REFERENCES users (id),
    cancelled     int         NOT NULL DEFAULT 0     -- pending matches the disable cancelled
);
CREATE INDEX season_map_events_map_idx ON season_map_events (season_map_id, at);

-- ------------------------------------------------------------ season baselines

-- A SEASON'S BASELINES ARE UPLOADED TO IT (N29), and they are the only opponents a trial can seat.
-- No image, release or bootstrap carries one, and a new season starts with none. There is no table
-- of them: a baseline is a `baseline.` account, its one entry, and its version in the season, and
-- that version's STATUS is whether it is in play --
--
--   testing   -- uploaded, and being admitted by the same walk a competitor's submission takes
--   rejected  -- admission refused it; a new upload under the same name is allowed
--   disabled  -- admitted, and out of play (every upload lands here, as a map lands switched off)
--   active    -- in play: paired, rated, on the ladder, and seated opposite every trial
--
-- The status and not a flag beside it, because every reader that asks "is this in play" already
-- asks `status = 'active'`, and a second column is a question each of them could forget.
--
-- What the status cannot hold is WHO did it and WHEN, so this is the record: the upload, and every
-- enable and disable, with how many queued matches a disable cancelled. Never deleted, like the
-- version it is about.
CREATE TABLE baseline_events (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    version_id  uuid        NOT NULL REFERENCES model_versions (id),
    at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    action      text        NOT NULL,
    by_user     uuid        NOT NULL REFERENCES users (id),
    cancelled   int         NOT NULL DEFAULT 0,     -- pending matches a disable cancelled
    CONSTRAINT baseline_events_action CHECK (action IN ('upload', 'enable', 'disable'))
);
CREATE INDEX baseline_events_version_idx ON baseline_events (version_id, at);

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
    -- THE BOARD, pinned at pair (N28). The season's maps change while it is live; this row's does
    -- not, and the claim reads the board through it. seat_count is that board's players, which
    -- pair's insert derives rather than trusts.
    season_map_id        uuid         NOT NULL REFERENCES season_maps (id),
    seat_count           smallint     NOT NULL,
    ladders              ladder[]     NOT NULL,   -- derived at insert; empty for a trial
    trial_version_id     uuid         REFERENCES model_versions (id),
    pairing_id           uuid,                    -- the pairing run that proposed it, for audit

    -- THE RULE THE WAVE PLAYS BY, pinned here rather than read at judging time -- the same reason
    -- engine_digest is a copy and not a lookup. Kalam applies it turn by turn and count reads its
    -- consequences off the seat, and neither may consult a config the other cannot see: before this
    -- column the two agreed only because devops/scripts/check/configs.sh asserted two [vars] equal.
    --
    -- NOT NULL is the point. `coalesce(rule, var)` with both null yields null, and on this column
    -- that is a constraint violation at pair's insert -- which halts loudly, in the right place --
    -- instead of Kalam's `{">=": [1, null]}` forfeiting every seat on turn 0 and the wave dying two
    -- turns later at `step`, naming neither the variable nor the cause.
    strike_ceiling       smallint     NOT NULL DEFAULT 5,

    -- ---- the lease
    claim_token          uuid,
    lease_expires_at     timestamptz,
    lapses               smallint     NOT NULL DEFAULT 0,   -- leases that expired mid-play
    refusals             smallint     NOT NULL DEFAULT 0,   -- loader refusals for want of memory

    -- WHICH MACHINE HOLDS IT, written at claim. Not a security control -- a runner is operated by
    -- an admin -- but without it every operational question about the fleet is unanswerable: which
    -- machine played this match, and which machine is wedged. Nullable because an in-cluster
    -- replica claiming over `kalam-db` writes no runner id, and because a reaped row keeps the
    -- attribution of the attempt that lapsed.
    played_by            uuid         REFERENCES runners (id),

    -- ---- what Kalam reports
    reason               text,        -- free text, never an enum: game-defined
    turns                int,
    played_ms            int,
    engine_digest_played text,        -- what actually ran; compare with engine_digest for skew
    orion_version        text,        -- which Orion ran the adapters; a sweep is per upgrade (R10)
    replay_key           text,        -- names the attempt, so a stale attempt's blob is an orphan
    played_at            timestamptz,
    fault_reason         text,
    fault_seat           smallint,    -- which seat is to blame, when one is
    closed_at            timestamptz,

    -- ---- what withdraw reports
    withdrawn_reason     text,
    successor_version_id uuid         REFERENCES model_versions (id),

    -- ---- what count reports
    rated_at             timestamptz,
    rated_seq            bigint,

    CONSTRAINT matches_seat_count         CHECK (seat_count >= 2),
    CONSTRAINT matches_strike_ceiling     CHECK (strike_ceiling > 0),
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
                              AND orion_version IS NOT NULL AND rated_at IS NULL
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
-- seat could name a version that does not exist or one from another game. It is also what makes
-- "every match this version played" an index scan.
--
-- seat IS the index: seat 0 is the first player, the addressing ants/docs/protocol.md uses.
CREATE TABLE match_seats (
    match_id       uuid     NOT NULL REFERENCES matches (id) ON DELETE CASCADE,
    seat           smallint NOT NULL,

    -- ---- what pair writes
    version_id     uuid     NOT NULL REFERENCES model_versions (id),
    weights_hash   text     NOT NULL,   -- copied at insert: the row records what was paired,
    manifest_hash  text     NOT NULL,   -- not what the version row says today
    paired_ratings jsonb,               -- the rating snapshot the pairing was made on

    -- ---- what Kalam writes
    rank           smallint,            -- 1 = best; ties allowed; forfeits last
    score          int,                 -- integer by law: game state carries no floats
    strikes        smallint,

    -- What this seat's model COST, summed over the turns it was actually played. Each turn's figure
    -- is the loader's `infer_us` -- the row's share of its own group's inference -- and NOT the
    -- row's elapsed time, which is a latency that includes waiting behind other competitors.
    --
    -- Comparable in a way no absolute measurement is: every seat of a match is a row of the same
    -- /play call, on one replica, at one instant, so machine, load and thermal state are shared and
    -- the comparison between seats is paired. Across matches it is only indicative.
    --
    -- `infer_turns` rather than reusing matches.turns: a seat that forfeited stopped being played,
    -- so the match's turn count would understate its mean. Two seats naming the same weights_hash
    -- batch into one inference and are charged an equal share of it.
    infer_us_total bigint,
    infer_us_max   int,
    infer_turns    int,

    PRIMARY KEY (match_id, seat),
    CONSTRAINT match_seats_seat_nonneg    CHECK (seat >= 0),
    -- Timing is deliberately NOT in here, though it is written by the same statement. It drives
    -- nothing -- no rating, no rank, no verdict -- so binding it to the result would buy no
    -- correctness and cost two things: a row finished by a Kalam that predates the columns would
    -- violate the CHECK and halt the wave mid-deploy, and an unmeasured seat would have to carry a
    -- fake 0 instead of an honest NULL.
    CONSTRAINT match_seats_result_whole   CHECK ((rank IS NULL) = (score IS NULL)
                                             AND (rank IS NULL) = (strikes IS NULL)),
    CONSTRAINT match_seats_rank_positive  CHECK (rank IS NULL OR rank >= 1),
    CONSTRAINT match_seats_strikes_nonneg CHECK (strikes IS NULL OR strikes >= 0),
    CONSTRAINT match_seats_timing_whole   CHECK ((infer_us_total IS NULL) = (infer_us_max IS NULL)
                                             AND (infer_us_total IS NULL) = (infer_turns IS NULL)),
    CONSTRAINT match_seats_timing_nonneg  CHECK (infer_us_total IS NULL OR
                                                (infer_us_total >= 0 AND infer_us_max >= 0
                                                 AND infer_turns >= 0)),
    -- The worst single turn cannot exceed the sum of every turn. Cheap, and it is the assertion that
    -- catches an accumulator wired to the wrong field.
    CONSTRAINT match_seats_timing_ordered CHECK (infer_us_total IS NULL
                                                 OR infer_us_max <= infer_us_total)
);

-- -------------------------------------------------------------- rating_events

-- One row per seat per ladder per counted match, plus a seed row at promotion (seq = 0).
--
-- The primary key IS the correctness argument: (version_id, ladder, seq) with seq taken from
-- ratings.matches_played means a second fold of the same match collides rather than
-- double-counting, and the chain -- every event starting where the previous one ended -- is then
-- checkable by a join.
CREATE TABLE rating_events (
    version_id   uuid        NOT NULL REFERENCES model_versions (id) ON DELETE CASCADE,
    ladder       ladder      NOT NULL,
    seq          int         NOT NULL,
    match_id     uuid        REFERENCES matches (id),
    seat         smallint,
    mu_before    float8,
    sigma_before float8,
    mu_after     float8      NOT NULL,
    sigma_after  float8      NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (version_id, ladder, seq),
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

-- model_versions ------------------------------------------------------------

-- Version numbers restart per entry. v1 of one entry and v1 of another are versions of different
-- things, and an entry whose history began at 7 because its owner had an earlier entry would be a
-- lie the Version screen prints. This index is also the model_id lookup every other statement uses.
CREATE UNIQUE INDEX model_versions_model_version_uniq
    ON model_versions (model_id, version);

-- At most one submission in flight PER ENTRY, spanning both pre-active states: an entry with a
-- verified version waiting for its trial may not take another release. The per-USER ceiling ACROSS
-- entries is entries.in_flight_max and is deliberately not here -- an index that says "one" and a
-- count that says "one" are two rules that will one day say different numbers.
CREATE UNIQUE INDEX model_versions_one_in_flight_uniq
    ON model_versions (model_id) WHERE status IN ('testing', 'verified');

-- The admission claim: testing rows, oldest first. Deliberately WITHOUT admit_started_at -- a
-- claim rewrites that column on every row it takes, and keeping it out leaves those updates
-- heap-only.
CREATE INDEX model_versions_admit_claim_idx
    ON model_versions (created_at) WHERE status = 'testing';

-- class ladders, by season; the season_id prefix also serves the open ladder
CREATE INDEX model_versions_season_class_active_idx
    ON model_versions (season_id, weight_class)
    WHERE status = 'active';

-- At most one contesting version PER ENTRY per season -- as a DEFERRABLE exclusion constraint
-- rather than a partial unique index, so promotion's single statement does not depend on CTE order:
-- Postgres does not order the updates of sibling CTEs, and checked at commit both orders succeed.
-- A closed season's final version stays `active` (it is the standing) while the same entry contests
-- the next.
--
-- It is also what makes count's predecessor read PROVABLY single-row. The (owner_id, game_id,
-- season_id) form it replaces did not: a competitor holds an `active` row in every season they ever
-- finished, so count's owner-scoped scalar subquery -- which carries no season term -- would have
-- raised "more than one row returned by a subquery used as an expression" the first time a second
-- season opened, and taken the whole ladder down with it.
ALTER TABLE model_versions
    ADD CONSTRAINT model_versions_one_active_excl
        EXCLUDE USING btree (model_id WITH =, season_id WITH =)
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

-- A disable's cancel: the pending rows on one board.
CREATE INDEX matches_pending_map_idx
    ON matches (season_map_id) WHERE status = 'pending';

-- One live trial per candidate. 'finished' is inside the predicate on purpose: a trial played but
-- not yet decided still counts as live, so pair cannot insert a second one in the window between
-- Kalam finishing it and count deciding it.
CREATE UNIQUE INDEX matches_one_live_trial_uniq
    ON matches (trial_version_id)
    WHERE trial_version_id IS NOT NULL AND status IN ('pending', 'claimed', 'running', 'finished');

-- how many trials a candidate has had, for the re-pair cap
CREATE INDEX matches_trial_history_idx
    ON matches (trial_version_id) WHERE trial_version_id IS NOT NULL;

-- How many rows one runner is holding: the claim's in-flight ceiling and nothing else. Partial,
-- like every other index on this table, and read once per claim as an uncorrelated InitPlan rather
-- than per candidate row. `played_by` is written ONCE, at claim, so indexing it costs the claim's
-- page and nothing on the renew path -- which is the same reason lease_expires_at is NOT indexed.
CREATE INDEX matches_runner_in_flight_idx
    ON matches (played_by) WHERE status IN ('claimed', 'running');

-- match_seats ---------------------------------------------------------------

-- a version's matches: GET /matches?version={id}, and the demand view's in-flight count
CREATE INDEX match_seats_version_idx
    ON match_seats (version_id, match_id);

-- the claim's affinity fill: rows whose models a replica already holds
CREATE INDEX match_seats_weights_idx
    ON match_seats (weights_hash, match_id);

-- rating_events -------------------------------------------------------------

-- the rating change a given match produced, for the Version screen
CREATE INDEX rating_events_match_idx
    ON rating_events (match_id, seat);

-- There is deliberately no index on ratings.conservative. Only active versions are ranked, status
-- lives on model_versions, and Postgres cannot build a partial index across a join -- so it would
-- be walked past every superseded and rejected version. The leaderboard is a join filtered by
-- model_versions_season_class_active_idx, sorted afterward.

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
-- resolve a season this way and a seventh does with `?season=<slug>` (p_slug), which is the same
-- selection with the slug pinned.
CREATE FUNCTION current_season(p_game uuid, p_slug text DEFAULT NULL)
RETURNS SETOF seasons LANGUAGE sql STABLE AS $$
    SELECT * FROM seasons s
     WHERE s.game_id = p_game AND (p_slug IS NULL OR s.slug = p_slug)
     ORDER BY (s.closed_at IS NULL) DESC, s.number DESC
     LIMIT 1;
$$;

-- WHAT OF THE RULES A SEASON MAY SHOW THE WORLD. season_json() is returned by six public routes,
-- and it used to return `rules` verbatim -- which published `participants.user_ids`, the roster of
-- a private cohort, to anyone who asked for the game. Everything else in the document is the
-- contest a competitor is entering and belongs on the page; the participant list is the one part
-- that names people, so it is reduced to whether it is on.
CREATE FUNCTION season_rules_public(r jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN r ? 'participants'
                THEN jsonb_set(r, '{participants}',
                               jsonb_build_object('enabled',
                                   coalesce(r -> 'participants' -> 'enabled', 'false'::jsonb)))
                ELSE r END;
$$;

-- The season object every route returns. The counts are the ones the site prints, and they are
-- different questions: `entries` is how many models are in the field, `active_versions` the
-- ladder's size, `entered_versions` everything ever submitted, `in_flight_versions` what "18
-- versions are mid-trial" means. `matches_played` EXCLUDES TRIALS so it agrees with what
-- GET /v1/matches can reach.
CREATE FUNCTION season_json(s seasons) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'name',   s.name,
        'slug',   s.slug,
        'state',  season_state(s),
        'submissions_open_at',  s.submissions_open_at,
        'submissions_close_at', s.submissions_close_at,
        'closed_at',            s.closed_at,
        'close_requested_at',   s.close_requested_at,
        'engine_digest',        s.engine_digest,
        'rules',                season_rules_public(s.rules),
        -- The caps this season is played under: they are per season, and a standing cannot be read
        -- without them.
        'weight_classes',       s.weight_classes,
        'entries',            (SELECT count(DISTINCT v.model_id) FROM model_versions v
                               WHERE v.season_id = s.id),
        'active_versions',    (SELECT count(*) FROM model_versions v
                               WHERE v.season_id = s.id AND v.status = 'active'),
        'entered_versions',   (SELECT count(*) FROM model_versions v
                               WHERE v.season_id = s.id),
        'matches_played',     (SELECT count(*) FROM matches mt
                               WHERE mt.season_id = s.id AND mt.status IN ('finished', 'rated')
                                 AND mt.trial_version_id IS NULL),
        'in_flight_versions', (SELECT count(*) FROM model_versions v
                               WHERE v.season_id = s.id AND v.status IN ('testing', 'verified')),
        -- The boards, summarised: how many are in play, how many are not, and the seats and sides
        -- the ones in play span. The boards themselves are GET .../seasons/{slug}/maps.
        'maps', (SELECT json_build_object(
                    'enabled',  count(*) FILTER (WHERE sm.enabled),
                    'disabled', count(*) FILTER (WHERE NOT sm.enabled),
                    'players',  CASE WHEN bool_or(sm.enabled) THEN json_build_array(
                                    min(sm.players) FILTER (WHERE sm.enabled),
                                    max(sm.players) FILTER (WHERE sm.enabled)) END,
                    'sides',    CASE WHEN bool_or(sm.enabled) THEN json_build_array(
                                    min(least(sm.rows, sm.cols)) FILTER (WHERE sm.enabled),
                                    max(greatest(sm.rows, sm.cols)) FILTER (WHERE sm.enabled)) END)
                   FROM season_maps sm WHERE sm.season_id = s.id),
        -- The baselines, summarised the same way (N29): in play, admitted and out of play, and still
        -- being admitted. A trial is seated only against the first number, so a season whose
        -- `enabled` is 0 pairs no trial. The list itself is the admin's GET .../seasons/{slug}/baselines.
        'baselines', (SELECT json_build_object(
                    'enabled',   count(*) FILTER (WHERE v.status = 'active'),
                    'disabled',  count(*) FILTER (WHERE v.status = 'disabled'),
                    'admitting', count(*) FILTER (WHERE v.status = 'testing'))
                   FROM model_versions v
                   JOIN models e ON e.id = v.model_id
                   JOIN users u  ON u.id = e.owner_id AND u.role = 'baseline'
                  WHERE v.season_id = s.id));
$$;

-- THE HEADER OF AN UPLOADED MAP, or NULL when the file has none worth reading (N28): an `id` that
-- is a slug and whole-number `players`, `rows` and `cols`. It is what the platform reads out of a
-- board and ALL it reads -- the rest of the file is the cartridge's, judged by its own worldgen.
-- Each cast sits behind the pattern that makes it safe, so a file saying "players": "two" is a NULL
-- header and a 400, never a 22P02 on the upload path.
CREATE FUNCTION season_map_header(v jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(v) = 'object'
         AND jsonb_typeof(v -> 'id') = 'string'
         AND (v ->> 'id') ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(v ->> 'id') <= 64
         AND jsonb_typeof(v -> 'players') = 'number' AND (v ->> 'players') ~ '^[0-9]{1,3}$'
         AND jsonb_typeof(v -> 'rows') = 'number' AND (v ->> 'rows') ~ '^[0-9]{1,3}$'
         AND jsonb_typeof(v -> 'cols') = 'number' AND (v ->> 'cols') ~ '^[0-9]{1,3}$'
        THEN jsonb_build_object('id', v ->> 'id', 'players', (v ->> 'players')::int,
                                'rows', (v ->> 'rows')::int, 'cols', (v ->> 'cols')::int)
    END;
$$;

-- WHETHER A HEADER FITS THE GAME'S ENVELOPE: the cartridge's `limits.boards`, which it derives from
-- the basic boards admission's reference set is drawn on. Seats, each side, and the cells an
-- adapter's cost scales with -- the side alone would let a square board of the largest side through
-- with more cells than any board an adapter was proved on. NULL, and so a refusal, for a cartridge
-- that declares no envelope: an engine from before N28 has made no promise to check against.
CREATE FUNCTION season_map_within(h jsonb, l jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT (h ->> 'players')::int BETWEEN (l -> 'players' ->> 0)::int AND (l -> 'players' ->> 1)::int
       AND (h ->> 'rows')::int BETWEEN (l -> 'sides' ->> 0)::int AND (l -> 'sides' ->> 1)::int
       AND (h ->> 'cols')::int BETWEEN (l -> 'sides' ->> 0)::int AND (l -> 'sides' ->> 1)::int
       AND (h ->> 'rows')::int * (h ->> 'cols')::int <= (l ->> 'cells_max')::int;
$$;

-- ONE SEASON MAP, as four routes return it (N28): the header the platform reads, whether it is in
-- play, and how many counted matches it has carried. The board itself is not here -- it is the
-- cartridge's, and only the routes that draw one ask for it, beside this.
CREATE FUNCTION season_map_json(sm season_maps) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'map_id',   sm.map_id,
        'players',  sm.players,
        'rows',     sm.rows,
        'cols',     sm.cols,
        'enabled',  sm.enabled,
        'added_at', sm.added_at,
        'matches',  (SELECT count(*) FROM matches m
                      WHERE m.season_map_id = sm.id AND m.status IN ('finished', 'rated')
                        AND m.trial_version_id IS NULL));
$$;

-- A BASELINE'S ACCOUNT, from the name an admin gives it (N29): `baseline.` and the name's slug, by
-- the rule a season's slug follows. "Scout" and "scout" are one baseline, and the same name in a
-- later season is that baseline again, with a new version. NULL for a name that leaves no usable
-- slug, which the upload refuses as baseline_name_unusable.
CREATE FUNCTION baseline_handle(p_name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN char_length(btrim(p_name)) BETWEEN 1 AND 48
                 AND season_slug(btrim(p_name)) ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                THEN 'baseline.' || season_slug(btrim(p_name)) END;
$$;

-- ------------------------------------------------ the season's rules, as predicates
--
-- Each rule below is asked TWICE per attempt -- once by the write that must not happen and once by
-- the read that says why it did not -- and the two answers have to be the same answer, or a
-- competitor is refused for a reason the response denies. That is why each is one function and
-- never two expressions.
--
-- Each counts WITHIN THE SEASON WHOSE RULE IT IS. A document reaching back into a previous season's
-- rows would make a competitor's allowance depend on a competition that is over.

-- The participants rule. EITHER list admits, and `handles` is resolved at the time of asking rather
-- than at the season create: a cohort is a list of GitHub logins written before the term starts, and
-- resolving it once would silently refuse every member who signed in for the first time afterwards
-- -- which is most of them. users.handle IS the GitHub login, rewritten on every sign-in, so the
-- match is on lower(handle) and needs no second table.
CREATE FUNCTION season_admits(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'participants' ->> 'enabled')::bool, false)
        OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(
                            coalesce(s.rules -> 'participants' -> 'user_ids', '[]'::jsonb)) AS uid
                    WHERE uid = (p_user)::text)
        OR EXISTS (SELECT 1 FROM users u
                    WHERE u.id = p_user
                      AND lower(u.handle) IN (
                          SELECT lower(h) FROM jsonb_array_elements_text(
                              coalesce(s.rules -> 'participants' -> 'handles', '[]'::jsonb)) AS h));
$$;

-- No one else already holds these weights, within the rule's scope.
--
-- The three scopes are not a widening. `game` and `season` ask "does another COMPETITOR hold these
-- weights" and always let a competitor resubmit their own. `user` is the one that can refuse the
-- caller, and it exists because the entry split made the old behaviour wrong: with many entries per
-- user, "always exempt your own rows" is exactly the licence to stand one set of weights on five
-- entries and take five ladder slots. Under `user` the only exempt rows are THIS ENTRY'S, which is
-- what keeps re-submitting a fixed release working.
--
-- A rejected row holds no hash worth counting: the commonest rejection is HASH_MISMATCH, which
-- means those bytes were never there.
CREATE FUNCTION season_admits_weights(s seasons, p_user uuid, p_hash text,
                                      p_model uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'unique_weights' ->> 'enabled')::bool, false)
        OR NOT EXISTS (
               SELECT 1
                 FROM model_versions v
                 JOIN models e ON e.id = v.model_id
                WHERE e.game_id = s.game_id
                  AND v.weights_hash = p_hash
                  AND v.status <> 'rejected'
                  AND CASE coalesce(s.rules -> 'unique_weights' ->> 'scope', 'game')
                        WHEN 'game'   THEN e.owner_id <> p_user
                        WHEN 'season' THEN e.owner_id <> p_user AND v.season_id = s.id
                        WHEN 'user'   THEN e.id IS DISTINCT FROM p_model
                      END);
$$;

-- entries.max_per_user -- asked by the ENTRY create. A retired entry frees its slot.
CREATE FUNCTION season_admits_entry(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false)
        OR (s.rules -> 'entries' -> 'max_per_user') IS NULL
        OR (SELECT count(*) FROM models e
             WHERE e.owner_id = p_user AND e.game_id = s.game_id AND e.retired_at IS NULL)
           < (s.rules -> 'entries' ->> 'max_per_user')::int;
$$;

-- entries.in_flight_max -- the per-USER ceiling across entries. The per-ENTRY rule is
-- model_versions_one_in_flight_uniq and is deliberately not restated here.
CREATE FUNCTION season_admits_in_flight(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false)
        OR (s.rules -> 'entries' -> 'in_flight_max') IS NULL
        OR (SELECT count(*) FROM model_versions v JOIN models e ON e.id = v.model_id
             WHERE e.owner_id = p_user AND v.season_id = s.id
               AND v.status IN ('testing', 'verified'))
           < (s.rules -> 'entries' ->> 'in_flight_max')::int;
$$;

-- entries.versions_max_per_model and .versions_max_per_user, in one predicate because the
-- submission is refused by whichever bites first and the `why` read says which.
CREATE FUNCTION season_admits_version(s seasons, p_user uuid, p_model uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false)
        OR ((  (s.rules -> 'entries' -> 'versions_max_per_model') IS NULL
            OR (SELECT count(*) FROM model_versions v
                 WHERE v.model_id = p_model AND v.season_id = s.id)
               < (s.rules -> 'entries' ->> 'versions_max_per_model')::int)
       AND (   (s.rules -> 'entries' -> 'versions_max_per_user') IS NULL
            OR (SELECT count(*) FROM model_versions v JOIN models e ON e.id = v.model_id
                 WHERE e.owner_id = p_user AND v.season_id = s.id)
               < (s.rules -> 'entries' ->> 'versions_max_per_user')::int));
$$;

-- The instant an entry may submit again, or NULL when it may now.
--
-- THE COOLDOWN IS THE ONE RULE THAT CANNOT ANSWER THE SAME TWICE: it is a function of now(), so the
-- insert and the `why` read a fraction of a second later can genuinely disagree, and will, exactly
-- at the boundary. The read therefore reports this INSTANT and never the boolean below, so the page
-- says "try again at 14:02" instead of refusing for a reason it then denies.
--
-- Per entry and not per user, which is not the obvious choice: a per-user cooldown would contradict
-- in_flight_max, because a competitor allowed three submissions at once could not make the second
-- and third. Per entry the two rules compose.
CREATE FUNCTION season_cooldown_until(s seasons, p_model uuid)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT max(v.created_at) + make_interval(secs => (s.rules -> 'entries' ->> 'cooldown_s')::float8)
      FROM model_versions v
     WHERE v.model_id = p_model AND v.season_id = s.id
       AND (s.rules -> 'entries' -> 'cooldown_s') IS NOT NULL
       AND coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false);
$$;

CREATE FUNCTION season_admits_cooldown(s seasons, p_model uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(season_cooldown_until(s, p_model), '-infinity'::timestamptz) <= now();
$$;

-- classes.allow -- asked by ADMISSION and by nothing else, because a submission cannot state its
-- class: admission measures it. It NARROWS weight_classes and never adds to it, so the class table
-- stays the one definition and its ascending order stays the reason the class pick is correct.
CREATE FUNCTION season_admits_class(s seasons, p_class ladder) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'classes' ->> 'enabled')::bool, false)
        OR (s.rules -> 'classes' -> 'allow') IS NULL
        OR (p_class)::text IN (SELECT jsonb_array_elements_text(s.rules -> 'classes' -> 'allow'));
$$;

-- entries.max_per_class -- asked by ADMISSION's verdict and never by the submission insert, for the
-- same reason: a submission has no class until admission measures it. Left in the insert it would
-- be a rule that answers differently when asked the second time, which is the exact failure the
-- ask-twice discipline exists to prevent.
CREATE FUNCTION season_admits_class_slot(s seasons, p_user uuid, p_class ladder, p_model uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false)
        OR (s.rules -> 'entries' -> 'max_per_class') IS NULL
        OR (SELECT count(DISTINCT v.model_id) FROM model_versions v JOIN models e ON e.id = v.model_id
             WHERE e.owner_id = p_user AND v.season_id = s.id AND v.weight_class = p_class
               AND v.status IN ('verified', 'active') AND v.model_id <> p_model)
           < (s.rules -> 'entries' ->> 'max_per_class')::int;
$$;

-- ------------------------------------------------------------ reading a ladder

-- THE FIELD ON ONE LADDER, and the one definition of who is on it. Two readers rank against this --
-- the leaderboard, and a version's own "rank 6 of 47" -- and a ladder whose two readers disagreed
-- about its membership would print a rank a page cannot justify.
--
-- standings.ranked_per_user_max is applied HERE and nowhere else. It is work the entry split makes
-- necessary: one active version per entry per season means a competitor with five entries holds
-- five rows, and without a cap the top ten is one name.
CREATE FUNCTION ladder_field(p_season uuid, p_ladder ladder)
RETURNS TABLE (version_id uuid, owner_id uuid, conservative float8)
LANGUAGE sql STABLE AS $$
    WITH cap AS (
        SELECT CASE WHEN coalesce((s.rules -> 'standings' ->> 'enabled')::bool, false)
                    THEN (s.rules -> 'standings' ->> 'ranked_per_user_max')::int END AS n
          FROM seasons s WHERE s.id = p_season),
    eligible AS (
        SELECT v.id, e.owner_id, r.conservative,
               row_number() OVER (PARTITION BY e.owner_id
                                  ORDER BY r.conservative DESC, v.id) AS per_owner
          FROM model_versions v
          JOIN models e   ON e.id = v.model_id
          JOIN ratings r  ON r.version_id = v.id AND r.ladder = p_ladder
         WHERE v.season_id = p_season AND v.status = 'active'
           AND (p_ladder = 'open' OR v.weight_class = p_ladder))
    SELECT eligible.id, eligible.owner_id, eligible.conservative
      FROM eligible, cap
     WHERE eligible.per_owner <= coalesce(cap.n, 2147483647);
$$;

-- Which of the two clocks a version is waiting on, in the words the pages print. Four routes say
-- this; a version whose row is 'testing' or 'verified' yields the first three states only.
CREATE FUNCTION model_phase(v model_versions) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN v.status = 'testing' AND v.admit_started_at IS NULL THEN 'queued'
                WHEN v.status = 'testing'   THEN 'verifying'
                WHEN v.status = 'verified'  THEN 'awaiting_trial'
                WHEN v.status = 'active'    THEN 'on_the_ladder'
                WHEN v.status = 'disabled'  THEN 'disabled'
                WHEN v.status = 'rejected'  THEN 'rejected'
                ELSE                             'superseded' END;
$$;

-- ONE SEASON BASELINE, as its three admin routes return it (N29): the name and the account, where
-- the version stands, what admission measured, and how it has done on the open ladder. `slug` is
-- how the routes address it -- the handle without its `baseline.` prefix.
CREATE FUNCTION season_baseline_json(v model_versions) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'slug',          substr(u.handle, length('baseline.') + 1),
        'name',          e.name,
        'handle',        u.handle,
        'model_id',      e.id,
        'version_id',    v.id,
        'version',       v.version,
        'status',        v.status,
        'phase',         model_phase(v),
        'enabled',       v.status = 'active',
        'reject_reason', v.reject_reason,
        'class',         v.weight_class,
        'size_bytes',    v.size_bytes,
        'params',        v.param_count,
        'infer_us',      v.infer_us,
        'weights_hash',  v.weights_hash,
        'added_at',      v.created_at,
        'rating',        (SELECT r.conservative FROM ratings r WHERE r.version_id = v.id AND r.ladder = 'open'),
        'matches',       (SELECT r.matches_played FROM ratings r WHERE r.version_id = v.id AND r.ladder = 'open'))
      FROM models e JOIN users u ON u.id = e.owner_id
     WHERE e.id = v.model_id;
$$;

-- A rating is half a sentence; the Version screen, the profile and the caller's own list all print
-- "rank 6 of 47" beside it. THE ORDER IS THE LEADERBOARD'S -- conservative DESC, id -- and the id
-- tiebreak is not decoration: two ratings can be equal to the last bit, and without it a version's
-- own page and the ladder it appears on would disagree about which of the pair is fifth. Both read
-- ladder_field(), so they also cannot disagree about who is on the ladder at all.
--
-- The field is the season's CURRENT field, since only `active` versions are on a ladder. A
-- superseded version keeps its ratings rows and gets a rank too: where it would place among the
-- versions playing now.
CREATE FUNCTION model_ratings(p_version uuid, p_settled_sigma float8)
RETURNS json LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_object_agg(r.ladder, json_build_object(
        'rating',      r.conservative,
        'mu',          r.mu,
        'sigma',       r.sigma,
        'provisional', r.sigma > p_settled_sigma,
        'matches',     r.matches_played,
        'rank',  (SELECT count(*) + 1 FROM ladder_field(v.season_id, r.ladder) f
                  WHERE f.conservative > r.conservative
                     OR (f.conservative = r.conservative AND f.version_id < v.id)),
        -- The version itself counts, whether or not it is ON the ladder. Without the second term a
        -- superseded version reads "rank 6 of 5": it is ranked against the live field but was not
        -- one of it. Dropped into the five playing now, it would be sixth of six. The test is
        -- membership and not `status = 'active'`, because standings.ranked_per_user_max can leave
        -- an active version off the ladder its own page still ranks it against.
        'field', (SELECT count(*) FROM ladder_field(v.season_id, r.ladder) f)
                 + (CASE WHEN EXISTS (SELECT 1 FROM ladder_field(v.season_id, r.ladder) f2
                                       WHERE f2.version_id = v.id) THEN 0 ELSE 1 END)
    )), '{}'::json)
    FROM ratings r JOIN model_versions v ON v.id = r.version_id
    WHERE r.version_id = p_version;
$$;

-- A match's seats, resolved: who sat there, in which class, and how it went for them. The three
-- match routes each return their own SHAPE -- the public listing, the caller's own and the match
-- page name different keys -- but the seat itself is one thing, and `outcome` is why this is a
-- function: a forfeited seat is `dq` and a beaten one is `loss`.
--
-- The strike limit is READ OFF THE MATCH ROW rather than passed in. It used to be a parameter every
-- caller had to plumb from the pair clock's config into a route, which meant a route's rendering
-- of a forfeit depended on a number in another package's [vars]. matches.strike_ceiling is the rule the
-- wave actually played by, so the seat is judged by it and by nothing else.
CREATE FUNCTION match_seat_rows(p_match uuid)
RETURNS TABLE (seat smallint, version_id uuid, model_id uuid, model_name text,
               owner text, owner_id uuid, baseline boolean,
               class ladder, version int, rank smallint, score int, strikes smallint, outcome text)
LANGUAGE sql STABLE AS $$
    SELECT s.seat, s.version_id, e.id, e.name, u.handle, e.owner_id, u.role = 'baseline',
           v.weight_class, v.version, s.rank, s.score, s.strikes,
           CASE WHEN s.rank IS NULL                    THEN NULL
                WHEN s.strikes >= m.strike_ceiling     THEN 'dq'
                WHEN s.rank > 1                        THEN 'loss'
                WHEN (SELECT count(*) FROM match_seats w
                       WHERE w.match_id = s.match_id AND w.rank = 1) > 1 THEN 'draw'
                ELSE                                        'win' END
      FROM match_seats s
      JOIN matches m           ON m.id = s.match_id
      LEFT JOIN model_versions v ON v.id = s.version_id
      LEFT JOIN models e       ON e.id = v.model_id
      LEFT JOIN users u        ON u.id = e.owner_id
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

-- ONE WRITER IS NOT CONFINED HERE, AND IT IS DELIBERATE. The /v1/runner/* routes run the eight
-- match statements from inside Soma's package, over `soma-db` -- the OWNER connection. So a runner's
-- claim, start, renew and finish are executed with full rights, and the column-level grant below is
-- not what stops one writing a rating; review is. That is a real weakening of the boundary and it
-- buys one package instead of two.
--
-- What still holds: a runner never reaches the database at all. It holds no credential, and every
-- statement it triggers is one of the eight shipped in soma/workflows/soma-runner-*.json, each
-- fenced on its claim token. The exposure is a bad statement in this repository, not a bad actor on
-- a desk -- which is the same class of risk every other Soma route already carries.
--
-- NARROWED, and the role that does it is `runner_gate` below. The paragraph that used to stand here
-- proposed a `soma-runner-db` connector on env://KALAM_DB_URL -- that is, on the `kalam` role --
-- and then forbade adding a grant to `kalam` in its own next sentence. Both halves were right and
-- together they were impossible: the routes need `played_by`, `live_runners` and the `runners`
-- upsert, none of which `kalam` may have. A third role is what satisfies both.
--
-- Do not add a grant to the `kalam` role to make a runner route work -- if it needs one, it is on
-- the wrong connector.

-- Kalam plays matches. It can read the two tables it plays from and write only the columns it
-- reports, so "Kalam writes no rating" is a fact of the grant: it cannot rate a match, cancel one,
-- pair one, or touch models, model_versions, ratings, users or clocks at all. It reads
-- matches.strike_ceiling off the row it claimed and keeps no copy of that number in its own config.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kalam') THEN
        CREATE ROLE kalam LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO kalam;
GRANT SELECT ON matches, match_seats TO kalam;
-- The board its claimed row is played on (N28), which db mode's K_ROW joins exactly as the gate's
-- claim does. The board and its id, and nothing about who uploaded it or when.
GRANT SELECT (id, map_id, board) ON season_maps TO kalam;
-- The roster a replica registers on its own node (decision R8): the manifest, where the bytes are
-- and the digest they must hash to. COLUMN-LEVEL on purpose -- `weight_class`, `param_count`,
-- `infer_us`, `reject_reason` and every admission column stay out of reach, so "Kalam reads no
-- competitive decision" survives it being able to name a model at all. It still cannot reach
-- ratings, users, seasons or clocks.
GRANT SELECT (id, status, manifest, artifact_key, weights_hash, created_at)
    ON model_versions TO kalam;
GRANT UPDATE (status, claim_token, lease_expires_at, lapses, refusals,
              reason, turns, played_ms, engine_digest_played, orion_version,
              replay_key, played_at, fault_reason, fault_seat, closed_at)
    ON matches TO kalam;
GRANT UPDATE (rank, score, strikes, infer_us_total, infer_us_max, infer_turns)
    ON match_seats TO kalam;
-- NOT `played_by`: an in-cluster replica writing over kalam-db is not a runner and has no runner id
-- to name. The column stays null for it, which is exactly the right answer to "which machine".

-- ------------------------------------------------------------ the runner gate

-- THE ROLE THE EIGHT MACHINE-FACING ROUTES RUN AS, and the repair of the one boundary the gate
-- weakened when it shipped inside this package instead of a second one (N7 -> N17).
--
-- It is a THIRD ROLE and not the `kalam` one, and that distinction is the whole point. The routes
-- need three things `kalam` deliberately does not have -- `played_by`, `live_runners`, and the
-- `runners` upsert the token exchange performs -- and widening `kalam` to supply them would widen
-- the role an IN-CLUSTER REPLICA still holds, which is what the paragraph above forbids. So the
-- grant that was going to be bent is copied instead, and the copy gets exactly the three additions.
--
-- WHAT IT CANNOT DO, and this is the list that matters: rate a match, cancel one, pair one, or
-- touch `ratings`, `rating_events`, `users`, `seasons`, `clocks`, `models` or `model_versions`
-- beyond the six roster columns. "A runner statement cannot write a rating" is a fact of this grant
-- again, rather than a fact of review.
--
-- THE FIVE ADMIN ROUTES STAY ON `soma-db`. `runner_keys` creation and revocation are Soma's auth
-- surface, the same as sessions, and they are session-authed rather than runner-authed -- so the
-- swap is eight workflows, not thirteen.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'runner_gate') THEN
        CREATE ROLE runner_gate LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO runner_gate;
GRANT SELECT ON matches, match_seats TO runner_gate;
GRANT SELECT (id, map_id, board) ON season_maps TO runner_gate;
GRANT SELECT (id, status, manifest, artifact_key, weights_hash, created_at)
    ON model_versions TO runner_gate;
-- The claim reads the row's own season and game to build the execution contract (N18). SELECT
-- only, and on the two columns that carry it: a runner's terms are read here, never decided here.
GRANT SELECT (id, game_id, rules, engine_digest, closed_at) ON seasons TO runner_gate;
GRANT SELECT (id, slug, manifest) ON games TO runner_gate;
-- `kalam`'s match columns, plus `played_by`, which the claim writes and which `kalam` must not have.
GRANT UPDATE (status, claim_token, lease_expires_at, lapses, refusals,
              reason, turns, played_ms, engine_digest_played, orion_version,
              replay_key, played_at, fault_reason, fault_seat, closed_at, played_by)
    ON matches TO runner_gate;
GRANT UPDATE (rank, score, strikes, infer_us_total, infer_us_max, infer_turns)
    ON match_seats TO runner_gate;
-- Runner identity, which the gate needs and a replica must not have: the key lookup the token
-- exchange probes by, the self-registration it performs, and the liveness JOIN every statement
-- carries. INSERT on `runners` because a runner self-registers; there is no enrolment flow.
GRANT SELECT ON live_runners, live_runner_keys TO runner_gate;
-- NOT `runner_keys` ITSELF, and not `users`: `live_runner_keys` is the join, so this role can match
-- a key to its runner without being able to read who holds it or what else they may do.

-- `id` ALONE, and it is the UPDATE's own WHERE that needs it: a WHERE on the target table is a
-- read, so stamping last_used_at by id requires SELECT on that column. It exposes row ids and
-- nothing else -- not the hash, not the prefix, not the owner. The match itself happens in
-- `live_runner_keys`, which is the whole reason that view exists.
GRANT SELECT (id) ON runner_keys TO runner_gate;
GRANT UPDATE (last_used_at) ON runner_keys TO runner_gate;
GRANT SELECT, INSERT ON runners TO runner_gate;
GRANT UPDATE (label, engine_digest, node_version, orion_version, ops_budget, arch, last_seen_at)
    ON runners TO runner_gate;

-- THE `kalam` ROLE IS GRANTED NOTHING ON runner_keys, runners, live_runners OR sessions, and the
-- absence is deliberate: runner identity is Soma's auth surface, the same as session identity, and
-- a replica has no more business reading who may start a runner than it has reading who may sign in.
--
-- THERE IS NO CLOCK ROLE. The clocks -- admit, pair, count, withdraw -- run as the owner over
-- `soma-db`, the connector the routes use. Until 16 September 2026 they were a separate package
-- over a `jodi` role with no DELETE anywhere, nothing on `sessions` and no UPDATE on `models`; the
-- package merged into this one and the role went with it. What still confines them is
-- `soma-db`'s `operations.delete = false` and review: a clock statement that deletes, reads
-- `sessions` or rewrites an entry is a review failure, not a grant error.

COMMIT;
