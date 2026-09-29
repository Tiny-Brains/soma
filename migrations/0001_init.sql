-- Soma -- the platform schema. One initial file rather than a migration chain: nothing is
-- released, so 0001 is rewritten in place until it is. Postgres 13+.
--
-- Two roles write this database (grants at the bottom of the file):
--   soma         -- the owner. The routes (users, sessions, an entry and a version) and the clocks
--                   (the version life cycle: matches, match_seats, ratings, rating_events, clocks).
--   runner_gate  -- the runner gate's routes and the reap clock: the columns a match player
--                   reports, runner identity, and the admission queue.
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

-- There is ONE rated ladder, 'open'; a weight class is a VIEW of it, filtered to same-size versions,
-- never its own rating. The class values remain because a class is still how a version is addressed
-- (model_versions.weight_class), how a leaderboard is filtered (ladder_field, the ?ladder= param),
-- and how a podium and a snapshot are labelled -- but ratings and rating_events carry 'open' alone.
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

    -- THE SEASON A GAME SHOWS WHEN NONE IS NAMED (N30): the default for every link and for a read
    -- with `?season=` left out. Set by the platform admin. NULL falls back, in current_season(), to
    -- the newest live public season, else the newest public season; a private season is never
    -- featured. The FK is added by ALTER after `seasons` exists (the two tables reference each other).
    featured_season_id   uuid,

    created_at           timestamptz NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------------- seasons

-- What seasons.weight_classes must look like, and the reason everything can trust that column.
-- ASCENDING AND STRICT is the load-bearing clause: admission takes the first class whose cap the
-- size fits, so an out-of-order table silently makes a class unreachable and equal caps make the
-- landing an accident of array order. Neither is an error the database could otherwise notice.
--
-- NO CAP ABOVE 64 MiB. Every node refuses an artifact past `[models] max_artifact_bytes` (64 MiB in
-- both soma's and the runner's template) before any class is considered, and a runner's model
-- memory is sized for it: 4 lanes x 8 seats x 64 MiB is its 2 GiB `max_loaded_bytes`. A larger cap
-- would name a class nothing could ever be admitted into.
--
-- A CLASS MAY ALLOW A MODEL MEMORY: `memory_flat_bytes` (0..262144) and `memory_cell_bytes` (0..16),
-- whole numbers, absent meaning 0. The cap on a board is flat + cell x rows x cols, and
-- memory_price() is the one place it is read. The ceilings are what a runner can carry: at both
-- tops a u8 memory on the largest board plus its seven i8 planes fits `max_input_elements`, and the
-- same memory plus a per-cell policy fits `max_output_elements`. web's configs.sh reads both
-- numbers out of this function, so raise one only with the runner's template.
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
              OR (e ->> 'max_bytes')::numeric > 67108864
              OR (e ->> 'max_bytes')::numeric <> trunc((e ->> 'max_bytes')::numeric)
              -- the memory numbers, when present: a whole number within its ceiling
              OR CASE jsonb_typeof(e -> 'memory_flat_bytes')
                     WHEN 'number' THEN (e ->> 'memory_flat_bytes')::numeric NOT BETWEEN 0 AND 262144
                                     OR (e ->> 'memory_flat_bytes')::numeric
                                        <> trunc((e ->> 'memory_flat_bytes')::numeric)
                     ELSE e ? 'memory_flat_bytes' END
              OR CASE jsonb_typeof(e -> 'memory_cell_bytes')
                     WHEN 'number' THEN (e ->> 'memory_cell_bytes')::numeric NOT BETWEEN 0 AND 16
                                     OR (e ->> 'memory_cell_bytes')::numeric
                                        <> trunc((e ->> 'memory_cell_bytes')::numeric)
                     ELSE e ? 'memory_cell_bytes' END)
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

-- The classes a season gets when its admin names none and no earlier season has any to inherit:
-- the column's default and season create's fallback, so the table exists once and cannot drift
-- past what weight_classes_ok() allows.
CREATE FUNCTION default_weight_classes() RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT '[{"class": "nano",  "max_bytes": 16384,    "memory_flat_bytes": 0, "memory_cell_bytes": 0},
             {"class": "micro", "max_bytes": 131072,   "memory_flat_bytes": 0, "memory_cell_bytes": 0},
             {"class": "mini",  "max_bytes": 1048576,  "memory_flat_bytes": 0, "memory_cell_bytes": 0},
             {"class": "small", "max_bytes": 8388608,  "memory_flat_bytes": 0, "memory_cell_bytes": 0},
             {"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 0, "memory_cell_bytes": 0}]'::jsonb;
$$;

-- A season's classes as every route returns them: in the table's own order, each with both memory
-- numbers, 0 where the admin left one out, so a reader never has to know that absent means 0.
CREATE FUNCTION weight_classes_public(wc jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_agg(e || jsonb_build_object(
                         'memory_flat_bytes', coalesce(e -> 'memory_flat_bytes', '0'::jsonb),
                         'memory_cell_bytes', coalesce(e -> 'memory_cell_bytes', '0'::jsonb))
                     ORDER BY t.ord)
      FROM jsonb_array_elements(wc) WITH ORDINALITY AS t (e, ord);
$$;

-- WHAT A MODEL'S MEMORY COSTS, AND WHETHER ITS CLASS ALLOWS IT: the one place the admit clock, and
-- any `why` or backfill, price a declaration. A model remembers by declaring an output named
-- `memory` (the board's: at most two named axes) or `ant_memory` (one row per ant: at most one),
-- which the runner hands back on the seat's next view. An output with a named axis costs per cell
-- -- a board axis binds to the board, and a seat never has more ants than the board has cells --
-- and one without costs a fixed amount; both outputs are summed:
--
--   bytes(cells) = fixed_bytes + cell_bytes x cells        cap(cells) = flat + cell x cells
--
-- Both sides are linear in the cell count, so checking the envelope's two ends -- the smallest
-- square board (sides_min squared) and `cells_max`, both from the game's `limits.boards` -- checks
-- every board a season can upload. The verdicts are final and the competitor's:
--   MEMORY_NOT_ALLOWED  a memory output, in a class whose numbers are both 0
--   MEMORY_SHAPE        not an output with a known dtype and a shape of whole numbers >= 1 and
--                       names, too many named axes, one name twice, or one output declared twice
--   MEMORY_TOO_LARGE    over the cap at either end
-- NO VERDICT AND NO BYTES is the one case that is not the model's: a memory the class allows, in a
-- game that declares no board envelope to price it against. The admit clock retries that.
--
-- The price is static. It trusts that a named axis binds to the board or the ant count; nothing
-- measures what a memory actually holds, and Orion refuses an output whose shape breaks its own
-- declaration on every call. Elements are clamped at 10^12, so no declaration overflows the sums.
CREATE FUNCTION memory_price(p_manifest jsonb, p_boards jsonb, p_class jsonb,
    OUT fixed_elems bigint, OUT cell_elems bigint, OUT fixed_bytes bigint, OUT cell_bytes bigint,
    OUT cells_min bigint, OUT cells_max bigint, OUT bytes_min bigint, OUT bytes_max bigint,
    OUT verdict text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    o        jsonb;
    d        jsonb;
    width    int;
    elems    numeric;
    named    text[];
    seen     text[]  := '{}';
    declared boolean := false;
    bad      boolean := false;
    fe       numeric := 0;
    ce       numeric := 0;
    fb       numeric := 0;
    cb       numeric := 0;
    flat     numeric := CASE WHEN jsonb_typeof(p_class -> 'memory_flat_bytes') = 'number'
                             THEN (p_class ->> 'memory_flat_bytes')::numeric ELSE 0 END;
    cell     numeric := CASE WHEN jsonb_typeof(p_class -> 'memory_cell_bytes') = 'number'
                             THEN (p_class ->> 'memory_cell_bytes')::numeric ELSE 0 END;
BEGIN
    FOR o IN SELECT e FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_manifest -> 'outputs') = 'array'
                                                     THEN p_manifest -> 'outputs'
                                                     ELSE '[]'::jsonb END) AS e
    LOOP
        CONTINUE WHEN jsonb_typeof(o) <> 'object'
                   OR coalesce(o ->> 'name', '') NOT IN ('memory', 'ant_memory');
        declared := true;
        bad := bad OR (o ->> 'name') = ANY (seen);
        seen := seen || (o ->> 'name');
        width := CASE o ->> 'dtype' WHEN 'f32' THEN 4 WHEN 'i32' THEN 4 WHEN 'u32' THEN 4
                                    WHEN 'f16' THEN 2 WHEN 'i16' THEN 2 WHEN 'u16' THEN 2
                                    WHEN 'i8'  THEN 1 WHEN 'u8'  THEN 1 WHEN 'bool' THEN 1
                                    WHEN 'f64' THEN 8 WHEN 'i64' THEN 8 WHEN 'u64' THEN 8 END;
        IF width IS NULL OR jsonb_typeof(o -> 'shape') IS DISTINCT FROM 'array' THEN
            bad := true;
            CONTINUE;
        END IF;
        elems := 1;
        named := '{}';
        FOR d IN SELECT x FROM jsonb_array_elements(o -> 'shape') AS x LOOP
            IF jsonb_typeof(d) = 'string' AND d #>> '{}' <> '' AND NOT (d #>> '{}') = ANY (named) THEN
                named := named || (d #>> '{}');
            ELSIF jsonb_typeof(d) = 'number' AND (d #>> '{}')::numeric >= 1
                  AND (d #>> '{}')::numeric = trunc((d #>> '{}')::numeric) THEN
                elems := least(elems * (d #>> '{}')::numeric, 1e12);
            ELSE
                bad := true;
            END IF;
        END LOOP;
        bad := bad OR cardinality(named) > CASE o ->> 'name' WHEN 'memory' THEN 2 ELSE 1 END;
        IF cardinality(named) > 0 THEN
            ce := least(ce + elems, 1e12);
            cb := least(cb + elems * width, 1e13);
        ELSE
            fe := least(fe + elems, 1e12);
            fb := least(fb + elems * width, 1e13);
        END IF;
    END LOOP;

    fixed_elems := fe;  cell_elems := ce;  fixed_bytes := fb;  cell_bytes := cb;
    cells_min := CASE WHEN jsonb_typeof(p_boards -> 'sides' -> 0) = 'number'
                      THEN ((p_boards -> 'sides' ->> 0)::numeric ^ 2)::bigint END;
    cells_max := CASE WHEN jsonb_typeof(p_boards -> 'cells_max') = 'number'
                      THEN (p_boards ->> 'cells_max')::numeric::bigint END;

    IF NOT declared THEN
        bytes_min := 0;
        bytes_max := 0;
        RETURN;
    END IF;
    bytes_min := least(fb + cb * cells_min, 1e18);
    bytes_max := least(fb + cb * cells_max, 1e18);
    IF flat = 0 AND cell = 0 THEN
        verdict := 'MEMORY_NOT_ALLOWED';
    ELSIF bad THEN
        verdict := 'MEMORY_SHAPE';
    ELSIF cells_min IS NULL OR cells_max IS NULL THEN
        bytes_min := NULL;              -- unpriced: no envelope to price against
        bytes_max := NULL;
    ELSIF bytes_min > flat + cell * cells_min OR bytes_max > flat + cell * cells_max THEN
        verdict := 'MEMORY_TOO_LARGE';
    END IF;
END;
$$;

-- ------------------------------------------------------- the season rules document

-- WHAT A SEASON'S RULES DOCUMENT MAY SAY: one row per key, and the reason every predicate further
-- down can read `rules` with a plain `->>` and a cast without a defensive coalesce around the
-- shape. A document that reached the column is a document of this shape.
--
-- Ten blocks, each with its own `enabled`, so a rule is turned on or off per season without a
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
    -- ---- participants LEFT THE RULES DOCUMENT (N30): a cohort is season_participants + `entry =
    --      'restricted'` now, so a class can add a late student after the season opens (rules freeze
    --      at open). season_admits reads the table; `entry` says what the rule's `enabled` said.
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
    --      The gate assembles the claim at the centre, where `matches -> seasons` is one join it
    --      already has, and sends these terms with it, so no runner keeps a copy and none has to
    --      be written onto a match row. matches.strike_ceiling is pinned per row (decision 54).
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
      -- Match length: the strategy horizon, and the compute a match costs. At most 1000, because a
      -- runner plays a match in one workflow run whose loop stops at 1010 sweeps (max_turns plus a
      -- tail); a longer match could never finish. web's configs.sh holds the two together.
      ('execution', 'max_turns',       'int',     1,   1000, NULL),
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
    -- ---- rounds: THE SEASON PLAYED IN ROUNDS, so a version's age is not its score. Every `days`
    --      from the window's open the withdraw clock schedules a season_rounds row; count applies it
    --      at its start (every active version's sigma raised to `sigma_floor`, mu drawn `mu_shrink`
    --      of the way to the season's mean) and pair gives every version the same `games` in it.
    --      `warn_minutes` before, the site says so. Absent keys are the generator's defaults (7
    --      days, 100 games, 15 minutes, no floor, no shrink). The finals are not a rule: an admin
    --      starts them, with their own numbers, once the window has closed (season_rounds).
      ('rounds', 'enabled',      'bool', NULL, NULL, NULL),
      ('rounds', 'days',         'int',     1,   60, NULL),
      ('rounds', 'games',        'int',     1, 100000, NULL),
      ('rounds', 'sigma_floor',  'num',  1e-9, 1000, NULL),
      ('rounds', 'mu_shrink',    'num',     0,    1, NULL),
      ('rounds', 'warn_minutes', 'int',     0, 1440, NULL),
    -- ---- closure: when the season ends. `finals` never settles itself: once the window closes it
    --      waits for an admin to start the finals, and closes when every entry has played them.
      ('closure', 'enabled',           'bool', NULL, NULL, NULL),
      ('closure', 'policy',            'enum', NULL, NULL, ARRAY['settle', 'deadline', 'admin', 'finals']),
      ('closure', 'settle_grace_days', 'int',     0,  365, NULL)
    ) AS t (block, key, kind, lo, hi, allowed);
$$;

-- Refuses an unknown key AT BOTH LEVELS, and every value that is not of its declared kind inside
-- its declared range. Both halves are the point: the CHECK this replaces enumerated two block names
-- and looked no further, so `{"unique_weights": {"enabld": true}}` stored cleanly and then read as
-- off through the coalesce every predicate uses, silently -- the typo disabling the rule.
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

-- THE FLEET POLICY'S SHAPE, and the reason it is a column and not a rule (see seasons.fleet below).
-- Two keys, `matches` and `admissions`, each `own | platform | both`: which runners may claim the
-- season's matches and admit its submissions. A column so a platform admin can change it WHILE THE
-- SEASON IS LIVE -- a university's runner dies mid-term and the platform steps in -- which a rule,
-- frozen at open, could not do. The default '{"matches":"platform","admissions":"platform"}' is
-- today's season: the platform fleet plays everything.
CREATE FUNCTION season_fleet_ok(f jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_typeof(f) = 'object'
       AND (f -> 'matches')    IS NOT NULL AND (f ->> 'matches')    IN ('own', 'platform', 'both')
       AND (f -> 'admissions') IS NOT NULL AND (f ->> 'admissions') IN ('own', 'platform', 'both')
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(f) AS k
                        WHERE k NOT IN ('matches', 'admissions'));
$$;

-- THE IDLE FILL'S SHAPE (seasons.fill below). `enabled`, always; `games`, the number of rated games
-- a version is topped up to in the window (the current round, or the season when it has none),
-- required while enabled; `headroom`, runner lanes left free for the queue a new submission makes.
CREATE FUNCTION season_fill_ok(f jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_typeof(f) = 'object'
       AND jsonb_typeof(f -> 'enabled') = 'boolean'
       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(f) AS k
                        WHERE k NOT IN ('enabled', 'games', 'headroom'))
       AND (f -> 'games' IS NULL
            OR (jsonb_typeof(f -> 'games') = 'number'
                AND (f ->> 'games')::numeric = trunc((f ->> 'games')::numeric)
                AND (f ->> 'games')::numeric BETWEEN 1 AND 100000))
       AND (f -> 'headroom' IS NULL
            OR (jsonb_typeof(f -> 'headroom') = 'number'
                AND (f ->> 'headroom')::numeric = trunc((f ->> 'headroom')::numeric)
                AND (f ->> 'headroom')::numeric BETWEEN 0 AND 1000))
       AND (NOT (f ->> 'enabled')::boolean OR f -> 'games' IS NOT NULL);
$$;

-- seasons.providers is null (any provider) or a JSON array of non-empty slug strings. A CHECK cannot
-- hold a subquery, so the array walk lives here (as season_fleet_ok's does).
CREATE FUNCTION season_providers_ok(p jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p IS NULL
        OR (jsonb_typeof(p) = 'array'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p) AS e
                             WHERE jsonb_typeof(e) <> 'string' OR (e #>> '{}') = ''));
$$;

-- A competition window for one game, created by an admin. A version belongs to exactly one season.
-- SEASONS OF A GAME OVERLAP (N30): a game may run any number of live seasons at once, public and
-- private, each with its own boards, baselines, participants, runners, podium and medals -- so
-- there is no non-overlap index and no gap between seasons. A season closes when its scores have
-- settled or when an admin asks. Its standings -- its `active` versions and their ratings -- are
-- kept for ever. `visibility` and `entry` decide who may see and who may enter it; `fleet` which
-- runners play it; `providers` which identity providers may enter it.
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

    -- COUNTED MATCHES, trials excluded: moved by count's fold, the statement that rates one, so
    -- season_json() reads a number rather than counting the season on every read.
    matches_played       int         NOT NULL DEFAULT 0,

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
    weight_classes       jsonb       NOT NULL DEFAULT default_weight_classes(),

    -- WHO MAY SEE, AND WHO MAY ENTER. `public` is watchable by the whole world; `private` is its
    -- participants', its season admins' and platform admins' alone -- to anyone else every route
    -- naming it answers as for a season that does not exist. `open` lets anyone who may see it
    -- enter; `restricted` lets only its participants (season_participants) enter. A CHECK holds
    -- `private` to `restricted`: a season no stranger can see is one no stranger can enter.
    visibility           text        NOT NULL DEFAULT 'public',
    entry                text        NOT NULL DEFAULT 'open',

    -- WHICH RUNNERS PLAY IT. Two keys, each own|platform|both; season_fleet_ok() above is the shape.
    -- A column, not a rule, because a platform admin changes it while the season is live.
    fleet                jsonb       NOT NULL DEFAULT '{"matches":"platform","admissions":"platform"}'::jsonb,

    -- THE IDLE FILL: what pair does with runner lanes nothing else wants. Off, the ladder asks only
    -- for what a round's quota or the settling rule asks for, and a settled field leaves the fleet
    -- idle while a version admitted last week sits on a tenth of the games of one admitted on day
    -- one. On, pair counts the free lanes of the runners that may play this season and queues
    -- matches into them, least-played version first, until every version has `games` in the
    -- window. A column and not a rule, like `fleet`: it is capacity, which changes with the fleet
    -- while the season is live, and it never moves a rating's meaning -- only how many games one
    -- rests on. season_fill_ok() above is the shape; the finals ignore it.
    fill                 jsonb       NOT NULL DEFAULT '{"enabled":false}'::jsonb,

    -- WHICH IDENTITY PROVIDERS MAY ENTER. NULL means any enabled provider (today's season). A JSON
    -- array of provider slugs restricts entry to identities from them: a university season lists its
    -- own provider so a GitHub identity cannot enter even if a login is listed. jsonb, not text[], so
    -- the request's JSON array binds without an array-literal round trip (an enum/array does not bind
    -- as a parameter). season_admits reads it with jsonb_array_elements_text.
    providers            jsonb,

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
    CONSTRAINT seasons_weight_classes_shape CHECK (weight_classes_ok(weight_classes)),
    CONSTRAINT seasons_visibility_shape CHECK (visibility IN ('public', 'private')),
    CONSTRAINT seasons_entry_shape      CHECK (entry IN ('open', 'restricted')),
    -- A private season is watchable only by its participants, so it can only be entered by them.
    CONSTRAINT seasons_private_restricted CHECK (visibility <> 'private' OR entry = 'restricted'),
    CONSTRAINT seasons_fleet_shape      CHECK (season_fleet_ok(fleet)),
    CONSTRAINT seasons_fill_shape       CHECK (season_fill_ok(fill)),
    CONSTRAINT seasons_providers_shape  CHECK (season_providers_ok(providers))
);

-- SEASONS OVERLAP (N30). There was a partial unique index here -- seasons_one_live_uniq, one live
-- season a game -- and it is gone: a game may run any number of live seasons at once. What was the
-- non-overlap rule is now the create accepting a season whatever else is live.

-- games.featured_season_id points into seasons, and seasons.game_id points into games: a cycle, so
-- one side is a plain column filled by ALTER once both tables exist. ON DELETE SET NULL because a
-- season is never deleted anyway (standings are kept for ever), but a featured pointer must not be
-- what would stop that if it ever were.
ALTER TABLE games
    ADD CONSTRAINT games_featured_season_fk
        FOREIGN KEY (featured_season_id) REFERENCES seasons (id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------- users

-- Baselines are users -- one per reference opponent, so they can be told apart on a ladder that
-- displays a model as its owner's handle. They never sign in, so they hold no `identities` row; an
-- admin makes one by uploading it into a season under a name (N29), and the account is
-- `baseline.<slug of that name>`: the same name in a later season is the same baseline again.
CREATE TABLE users (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- THE HANDLE: the account's stable public name, on the ladder and in its profile URL. SEEDED
    -- ONCE from the login of the identity that created the account (`seed_handle`) and never
    -- rewritten -- a competitor who renames themselves at a provider keeps their handle here, and
    -- the provider's current login is cached on `identities.login` instead. The account's stable
    -- identity is a row in `identities` keyed (provider, subject); a decision about who someone is
    -- belongs there, never on this label. The old model made this a live cache of the GitHub login
    -- and paid for it with a `released.` tombstone dance every sign-in; a per-identity login and a
    -- fixed handle need neither.
    --
    -- Uniqueness is on lower(handle), below, and not here. Every reader compares case-insensitively
    -- (the profile route and the participant match); a case-sensitive index and case-insensitive
    -- readers protect different namespaces, which is how `Alice` and `alice` could be two rows that
    -- both answer to one name.
    --
    -- ONE RESERVED PREFIX: `baseline.` for the uploaded reference opponents. `seed_handle` sanitises
    -- a provider login to [A-Za-z0-9-] before it becomes a handle, so no real account can land in
    -- the dotted namespace and collide with a baseline.
    handle      text        NOT NULL,

    -- Seeded from GitHub ON INSERT ONLY: overwriting it at every sign-in would silently undo the
    -- one field PATCH /v1/me lets a competitor edit. Null falls back to the handle.
    display_name text,

    -- One line a competitor writes about themselves, on their profile. REFUSED, not held, on a
    -- listed word (text_hold_tag): the author rewrites a line rather than waiting on an admin. A
    -- URL is allowed and drawn as plain text.
    bio         text,

    -- COMMENTING SWITCHED OFF, by an admin, until this instant -- `infinity` for good -- with the
    -- reason the author reads in the composer's place. The row holds only the current switch;
    -- every switch, on and off, is a line in audit_log.
    comments_off_until  timestamptz,
    comments_off_reason text,

    role        user_role   NOT NULL DEFAULT 'competitor',
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_bio_size CHECK (bio IS NULL OR char_length(bio) <= 160),
    CONSTRAINT users_comments_off_shape
        CHECK ((comments_off_until IS NULL) = (comments_off_reason IS NULL)
               AND (comments_off_reason IS NULL
                    OR (btrim(comments_off_reason) <> '' AND char_length(comments_off_reason) <= 300))),

    -- A baseline's handle lives in the reserved namespace and a human's never does -- the two are
    -- exactly the accounts without and with an `identities` row. Bidirectional, because `seed_handle`
    -- now sanitises arbitrary provider logins and a dotted login must not reach the baseline space.
    -- Without it a real account whose handle happened to equal a baseline's could never be created:
    -- the insert would collide on the handle index, unhandled, for ever.
    CONSTRAINT users_baseline_handle_reserved
        CHECK ((role = 'baseline') = (handle LIKE 'baseline.%'))
);

-- Case-insensitive, because every reader is. It is also the conflict target of every
-- INSERT ... ON CONFLICT on this table, and must be spelled `ON CONFLICT (lower(handle))` -- an
-- expression index is only a valid arbiter in the exact form it was declared in.
CREATE UNIQUE INDEX users_handle_uniq ON users (lower(handle));

-- ---------------------------------------------------------------- identities

-- HOW AN ACCOUNT SIGNS IN (§I). One row per (provider, subject): the provider's slug and the stable
-- subject it guarantees never changes and never reuses. `soma-pub-auth` upserts one on every
-- sign-in, keying the account on (provider, subject) and refreshing `login`. An account may hold
-- more than one -- a competitor who links a second provider -- and a baseline holds none. This is
-- what §I added: the single `users.github_id` it replaced could name one GitHub account and nothing
-- else, so a second provider had nowhere to live.
CREATE TABLE identities (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    -- The provider slug, the same vocabulary as season_participants.provider and a season's
    -- `providers` allow-list -- `github`, `google`, a tenant's directory. Lower-kebab, so it reads
    -- the same everywhere it is compared.
    provider    text        NOT NULL,

    -- The provider's STABLE id for the account (an OIDC `sub`, GitHub's numeric id). Always a
    -- string, the one shape every provider's subject fits; the sign-in upsert coerces a numeric id
    -- to text. This, with `provider`, is the conflict key -- never the login.
    subject     text        NOT NULL,

    -- The provider's CURRENT login/username: a CACHE OF A MUTABLE VALUE refreshed on every sign-in,
    -- used only to resolve a season_participants row listed by login before its owner has ever
    -- signed in. NULL for a provider with no login concept, or a userinfo answer that carried none.
    login       text,

    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT identities_provider_shape  CHECK (provider ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    CONSTRAINT identities_subject_shape   CHECK (btrim(subject) <> ''),
    CONSTRAINT identities_login_shape     CHECK (login IS NULL OR btrim(login) <> '')
);
-- The conflict target of the sign-in upsert: one account per (provider, subject).
CREATE UNIQUE INDEX identities_provider_subject_uniq ON identities (provider, subject);
CREATE INDEX identities_user_idx ON identities (user_id);
-- Participant resolution matches (provider, login) case-insensitively, the shape
-- season_participants_one_live_uniq has on the other side of the join.
CREATE INDEX identities_provider_login_idx ON identities (provider, lower(login));

-- Seed a fresh account's handle from the login of the identity creating it. A login is now a label
-- from an arbitrary provider, so it may be empty, may collide with an account that already holds it,
-- or may carry characters a handle (a public name, and a URL segment) must not. This sanitises it to
-- [A-Za-z0-9-], falls back to `<provider>-<subject>` when nothing is left, and disambiguates a
-- collision -- so the sign-in INSERT never fails on users_handle_uniq for a reason the competitor
-- cannot fix. STABLE, not IMMUTABLE: it reads `users` to check a collision, so it cannot be a CHECK.
CREATE FUNCTION seed_handle(p_login text, p_provider text, p_subject text) RETURNS text
    LANGUAGE sql STABLE AS $$
    WITH cand AS (
        SELECT COALESCE(
            NULLIF(btrim(regexp_replace(COALESCE(p_login, ''), '[^A-Za-z0-9-]+', '-', 'g'), '-'), ''),
            p_provider || '-' || p_subject
        ) AS c
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM users WHERE lower(handle) = lower((SELECT c FROM cand)))
            THEN (SELECT c FROM cand)
        WHEN NOT EXISTS (SELECT 1 FROM users
                          WHERE lower(handle) = lower((SELECT c FROM cand) || '-' || p_provider))
            THEN (SELECT c FROM cand) || '-' || p_provider
        ELSE (SELECT c FROM cand) || '-' || left(md5(p_provider || ':' || p_subject), 6)
    END;
$$;

-- ------------------------------------------------------------------- runners

-- WHO PLAYS A MATCH IS A ROW. A runner reaches the platform over /v1/runner/*, from hardware that
-- may be nowhere near the deployment, and these two tables are the whole of its identity: a
-- credential an admin holds, and a process that presented it.

-- ------------------------------------------------------ season admins & participants

-- SEASON ADMINS (N30). A MEMBERSHIP, NOT A ROLE: `user_role` stays competitor|admin|baseline, and a
-- season admin is a competitor everywhere else and may administer several seasons. A platform admin
-- assigns and removes them (by handle, at creation or later); a baseline account cannot be one.
-- live_runner_keys/live_runners will read this to let a season admin's runner keys work (Phase 3),
-- and the season-admin-only route fragment reads it on every request, so a removal takes effect at
-- the next call -- the same shape as an admin demotion.
CREATE TABLE season_admins (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    user_id     uuid        NOT NULL REFERENCES users (id),
    added_by    uuid        NOT NULL REFERENCES users (id),
    added_at    timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz
);
-- One live membership per (season, user); a removed one may be re-added.
CREATE UNIQUE INDEX season_admins_one_live_uniq
    ON season_admins (season_id, user_id) WHERE removed_at IS NULL;
CREATE INDEX season_admins_user_idx ON season_admins (user_id) WHERE removed_at IS NULL;

-- SEASON PARTICIPANTS (N30). Moved OUT of the `participants` rule and into a table, because rules
-- freeze when a season opens (count reads its rating constants off them) and a class must be able to
-- add a late student after the term starts. `entry = 'restricted'` plus rows here is what the rule
-- meant; `entry = 'open'` ignores the table. A row is a PROVIDER'S LOGIN, resolved to a user when
-- that identity exists -- pinned at add time, or at the identity's next sign-in -- and kept as a
-- login until then, since most of a class has never signed in when the roster is written. A NULL
-- login is a WILDCARD: every identity of the provider is a participant (I7/Q14), one row instead of a
-- roster. §I (the identity rebuild) has LANDED: `provider` is any provider slug, and resolution is
-- (provider, lower(login)) against the `identities` table (season_admits) -- the table's shape did
-- not change, only what a `login` is matched against. `DEFAULT 'github'` stays: it is the provider a
-- participants-add row omits, and the platform's public one.
CREATE TABLE season_participants (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    provider    text        NOT NULL DEFAULT 'github',
    login       text,                                    -- NULL is the provider-wide wildcard
    user_id     uuid        REFERENCES users (id),       -- pinned when the identity exists
    added_by    uuid        NOT NULL REFERENCES users (id),
    added_at    timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz,
    CONSTRAINT season_participants_login_shape    CHECK (login IS NULL OR btrim(login) <> ''),
    -- `slug_ok`'s rule, written out because that function is declared further down this file
    -- than this table. THE WRITER CALLS `slug_ok` (soma-user-participants-add's insert), so a
    -- malformed provider writes nothing and is diagnosed rather than raising 23514 here, which
    -- would make the route a 500. Keep the two in step: same shape, same length.
    CONSTRAINT season_participants_provider_shape CHECK (provider ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                                                     AND char_length(provider) <= 40)
);
-- One live row per (season, provider, login), case-insensitive; a removed row may be re-added. NULLs
-- are distinct in a unique index, so the wildcard (null login) needs its own one-live index.
CREATE UNIQUE INDEX season_participants_one_live_uniq
    ON season_participants (season_id, provider, lower(login)) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX season_participants_one_wildcard_uniq
    ON season_participants (season_id, provider) WHERE removed_at IS NULL AND login IS NULL;
CREATE INDEX season_participants_user_idx ON season_participants (user_id) WHERE removed_at IS NULL;

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

    -- WHICH SEASON THIS KEY (AND EVERY RUNNER STARTED FROM IT) SERVES (N30). NULL is the PLATFORM
    -- FLEET: it plays any season whose fleet policy allows the platform (fleet.matches/admissions in
    -- 'platform'|'both'). A value binds the key to ONE season for ever -- a season runner never serves
    -- another, whatever the other's policy says (R1) -- and it is minted on that season's admin page by
    -- its season admins. This is what makes delegating a runner to a stranger safe: a compromised
    -- season key can at worst play its own ladder. live_runner_keys/live_runners read it.
    season_id    uuid        REFERENCES seasons (id),

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

    -- REPORTED AT TOKEN EXCHANGE TOO: the longest match this node's channel can hold, and how many
    -- seats it asks at once. The claim hands a row only to a runner whose timeout covers the row's
    -- turn_ms x max_turns x ceil(seats / seat_concurrency) plus a tenth (match_execution() below the
    -- matches table), so a match a node cannot finish inside its deadline is never claimed, reaped
    -- and re-claimed for ever: it waits, pending and visible. NULL is a runner from before this was
    -- reported, or an admitting one, which the claim does not bound.
    match_timeout_ms bigint,
    seat_concurrency smallint,

    -- WHETHER IT PLAYS MATCHES: it has reported match slots at a token exchange. An admitting runner
    -- reports none (its row keeps the default four above, which it never uses), so pair's idle fill
    -- counts the lanes of these runners alone, rather than queueing work for slots nobody polls.
    plays_matches boolean     NOT NULL DEFAULT false,

    -- WHETHER IT ADMITS: the same fact for the other role, reported the same way (kalam's
    -- `admit_slots`, which RUNNER_ROLE=admit sets to one and a match runner leaves at zero). It is
    -- NOT `NOT plays_matches`: a runner that has reported neither is a runner from before either was
    -- reported, and reading silence as "this machine admits" is how an admin is told a queue is
    -- being served by a machine that has never claimed an admission. Both are sticky, because a
    -- token exchange that omits one says nothing about it rather than denying it.
    --
    -- WHAT IT IS FOR. Nothing admits while no admitting runner is up, and a season whose
    -- `fleet.admissions` is `own` has its own fleet to keep up; until this column existed the
    -- platform had no way to say so, and a submission sat in `testing` spending no attempt with
    -- nothing anywhere naming the reason. `admitters_up()` is the reader, and the runner is counted
    -- live on `last_seen_at` inside `runner_live_window()`, the same window pair's idle fill counts
    -- a match lane on.
    admits        boolean     NOT NULL DEFAULT false,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at    timestamptz,

    CONSTRAINT runners_max_in_flight_positive CHECK (max_in_flight > 0),

    UNIQUE (key_id, label)
);

-- HOW STALE `last_seen_at` MAY BE AND STILL MEAN "up". It must be at least the heartbeat's period,
-- and the heartbeat is slower than it looks: `soma-gate-token-register` is the ONLY statement that
-- writes `last_seen_at`, and a runner exchanges a token only when its cached one has expired --
-- kalam keeps it 480 s of its 600 (`shared/kalam.json`). A claim poll every 5 s touches nothing
-- here. So this was 90 seconds against a ~480 second heartbeat, and a perfectly healthy runner read
-- as down for about four fifths of every cycle: `admitters_up()` cried "nothing can admit" on
-- /v1/status and the season desk, and pair's idle fill summed a fleet of zero lanes and queued
-- nothing, on four ticks in five.
--
-- 600 s is the token's own life, so a runner that has not exchanged one inside it has missed its
-- renewal outright. The cost of the other direction -- a runner that dies is counted for up to ten
-- minutes -- is bounded and self-correcting: the fill queues rows nobody takes, they stay `pending`
-- and claimable, and `pair_depth_target` caps how many. Under-counting had no such floor.
CREATE FUNCTION runner_live_window() RETURNS interval
LANGUAGE sql IMMUTABLE AS $$ SELECT interval '600 seconds' $$;

-- live_sessions' argument applied to runners, and it is the same argument: a revoked key, a revoked
-- runner, a deleted user OR AN ADMIN WHO IS NO LONGER ONE all end the runner's next call. Every
-- runner statement JOINs this rather than trusting the bearer token it arrived with, so a demotion
-- takes effect at once -- the rule Soma's admin routes already follow by reading `role` off the
-- live row instead of off a cookie claim. A JSONLogic guard would fail OPEN if it were ever wrong;
-- a JOIN cannot be forgotten.
CREATE VIEW live_runners AS
    SELECT r.id, r.key_id, r.label, r.max_in_flight, r.match_timeout_ms, r.seat_concurrency, k.user_id,
           k.season_id
      FROM runners r
      JOIN runner_keys k ON k.id = r.key_id AND k.revoked_at IS NULL
      JOIN users u       ON u.id = k.user_id
     WHERE r.revoked_at IS NULL
       -- A PLATFORM key needs a live platform admin; a SEASON key needs a live season admin of ITS
       -- season (N30). Membership is read here, so a demoted admin's or a removed season admin's
       -- runner ends at its next call, the same fence a platform admin already had.
       AND ((k.season_id IS NULL AND u.role = 'admin')
         OR (k.season_id IS NOT NULL AND (u.role = 'admin' OR EXISTS (
                SELECT 1 FROM season_admins sa
                 WHERE sa.season_id = k.season_id AND sa.user_id = k.user_id AND sa.removed_at IS NULL))));

-- The key half of the same predicate, and it exists for the same reason `live_runners` does: the
-- token exchange has to know that a key belongs to a LIVE ADMIN, and the role that runs the
-- exchange must not be able to read `users` to find out. A view is owned by the schema owner and
-- runs with its privileges, so the join happens without the caller ever holding SELECT on `users`.
--
-- Demotion takes effect at the next token exchange, and revocation at the next CALL -- `live_runners`
-- is what carries the second, and it is stricter on purpose: a token already minted is bounded by
-- its ten minutes, but a statement is fenced now.
CREATE VIEW live_runner_keys AS
    SELECT k.id, k.user_id, k.key_hash, k.key_prefix, k.season_id
      FROM runner_keys k
      JOIN users u ON u.id = k.user_id
     WHERE k.revoked_at IS NULL
       -- Same reach as live_runners: a platform key of a live platform admin, or a season key of a
       -- live season admin of its season. Demotion takes effect at the next token exchange (N30).
       AND ((k.season_id IS NULL AND u.role = 'admin')
         OR (k.season_id IS NOT NULL AND (u.role = 'admin' OR EXISTS (
                SELECT 1 FROM season_admins sa
                 WHERE sa.season_id = k.season_id AND sa.user_id = k.user_id AND sa.removed_at IS NULL))));

-- HOW MANY ADMITTING RUNNERS COULD CLAIM THIS SEASON'S ADMISSIONS RIGHT NOW. Zero and a queue is
-- the one platform state that looks exactly like nothing being wrong: the admit clock prepares the
-- rows, no runner claims them, they spend no attempt, and the submission sits in `testing` (phase
-- `queued`) until it expires. `/v1/status`, the platform's Runners page and a season's own desk all
-- ask this, and the answer is the same predicate the admission claim itself runs
-- (soma-gate-admissions-claim-claim.sql), so the count can never disagree with what would be
-- claimed. Keep the two together: a change to the fleet reach there is a change here.
--
-- LIVE IS `last_seen_at` INSIDE 90 SECONDS, the window pair's idle fill counts a match lane on. An
-- admitting runner exchanges its token every ten minutes but claims every ten seconds, and
-- `live_runners` alone answers "not revoked", not "still breathing" -- a stopped container keeps
-- its row for ever. Nine missed ticks is down.
--
-- NULL SEASON MEANS THE WHOLE PLATFORM: how many admitting runners could claim ANY season's
-- admissions, which is what a platform-wide status line needs.
CREATE FUNCTION admitters_up(p_season uuid DEFAULT NULL) RETURNS integer
LANGUAGE sql STABLE AS $$
    -- DISTINCT because the join fans out: with no season named, one platform runner reaches every
    -- season whose policy allows it, and the answer is machines, not (machine, season) pairs.
    SELECT count(DISTINCT lr.id)::integer
      FROM live_runners lr
      JOIN runners r  ON r.id = lr.id
      JOIN seasons se ON se.closed_at IS NULL AND (p_season IS NULL OR se.id = p_season)
     WHERE r.admits
       AND r.last_seen_at > now() - runner_live_window()
       AND CASE WHEN lr.season_id IS NOT NULL
                THEN lr.season_id = se.id AND (se.fleet ->> 'admissions') IN ('own', 'both')
                ELSE (se.fleet ->> 'admissions') IN ('platform', 'both') END
$$;

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
-- `ants`: a name is not an identity, and nothing is decided on one. Who a competitor is, is a row in
-- `identities` (provider, subject) -- sign-in, which is the whole of what a provider does here now.
-- The repository that used to be the global key limited nothing (every ceiling is a season rule and
-- none of them mentioned it) and cost a normaliser, a season predicate, two indexes and an ownership
-- call that failed closed, so a rate-limited GitHub stopped anyone creating an entry at all.
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
    -- What the model's declared memory costs on the largest board (memory_price()'s bytes_max), 0
    -- for a model that declares none. Written with the class at admission, and null before it. Not
    -- part of the size: the class is decided by file bytes, and the memory is judged against it.
    memory_bytes    bigint,
    -- The slowest reference case's inference at admission, in microseconds -- or, on a version
    -- rejected PROBE_TOO_SLOW, the median probe its last attempt measured. Reported to the
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
    --
    -- A VERSION CAN REUSE ANOTHER'S BYTES (`bytes_of`): a baseline imported into a new season, or an
    -- entry re-entered with its last version, is a new version -- admitted again, under the new
    -- season's classes, memory and engine -- over files already in the bucket, which nothing then
    -- uploads or copies. Its key is its source's, and the source's own `bytes_of` is followed at
    -- the write, so a chain never forms.
    bytes_of         uuid REFERENCES model_versions (id),
    artifact_key     text GENERATED ALWAYS AS ('models/' || coalesce(bytes_of, id)::text || '/model.onnx') STORED,

    -- Which Orion served the verdict; a change in it is what makes a sweep necessary (R10). It
    -- replaces `evaluator_digest`, which named an axon build that no longer exists.
    orion_version    text,

    -- What the admission probe bound each named dimension to, as `{"H": 128, "W": 128}`. Without
    -- it `infer_us` is not comparable between two versions, because a variable axis means the
    -- number was measured at a size the manifest chose (R2).
    probe_dims       jsonb,

    reject_reason   text,

    -- The owner's one line about this version, public on the model page: written at submission and
    -- editable after. Refused on a listed word, like the bio.
    note            text,

    -- THE ADMIT CLOCK'S CLAIM, held while it prepares a submission for a runner and again while it
    -- judges what the runner found. One row per item, so this per-row claim is the mutual exclusion
    -- -- a run that dies mid-batch releases what it never reached at once, and the row it held after
    -- admit_timeout_s. The verdict re-checks admit_token, so a lapsed claim writes nothing. The
    -- ATTEMPTS are not here: an attempt is a runner's, and `admissions.attempts` counts them.
    admit_started_at timestamptz,
    admit_token      uuid,

    created_at      timestamptz  NOT NULL DEFAULT now(),

    FOREIGN KEY (model_id, game_id)  REFERENCES models  (id, game_id),
    FOREIGN KEY (season_id, game_id) REFERENCES seasons (id, game_id),

    CONSTRAINT model_versions_weight_class_not_open
        CHECK (weight_class <> 'open'),

    CONSTRAINT model_versions_version_positive
        CHECK (version >= 1),

    CONSTRAINT model_versions_note_size
        CHECK (note IS NULL OR (btrim(note) <> '' AND char_length(note) <= 120)),

    CONSTRAINT model_versions_memory_bytes_nonneg
        CHECK (memory_bytes IS NULL OR memory_bytes >= 0),

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

-- ----------------------------------------------------------------- admissions

-- ONE ROW PER SUBMISSION THE ADMIT CLOCK HAS PREPARED, and the queue an ADMITTING RUNNER claims
-- from. Soma runs no model: the clock checks what it can without one (the object is there, the
-- manifest hashes to its declaration, the registration rebuilt from it), writes this row, and a
-- runner whose role is `admit` does the rest on its own node -- registers the model, lets Orion admit
-- it, plays it over the game's reference observations, deletes it -- and reports what it found.
-- The clock judges the report. So a runner executes admission and never decides it: the report is
-- facts, the verdict is written by the clock, and a runner's role cannot reach model_versions.
--
-- Rows are never deleted (the clocks cannot), so a decided version keeps the last report it was
-- judged on.
CREATE TABLE admissions (
    version_id       uuid        PRIMARY KEY REFERENCES model_versions (id) ON DELETE CASCADE,

    -- WHAT THE CLOCK PREPARED. `registration` is the manifest rebuilt field by field AT THE CENTRE,
    -- `name` forced to the platform's model id, so a competitor's `reference` never reaches a node;
    -- it is all a runner is given of the manifest. `manifest` is the competitor's exact text, kept
    -- for the verdict (the hash is over it) and never sent. `artifact_bytes` is what the bucket
    -- answered the clock's own HEAD, so the size a class is judged on is never only a runner's word.
    registration     jsonb       NOT NULL,
    manifest         text        NOT NULL,
    artifact_bytes   bigint      NOT NULL,
    budget_ops       bigint      NOT NULL,
    prepared_at      timestamptz NOT NULL DEFAULT now(),

    -- THE RUNNER'S CLAIM: a lease and a token, as a match has, minted by the gate. Nothing renews
    -- it -- one admission is a few seconds of work -- so a lease that lapses is a runner that
    -- vanished, and the next claim takes the row. `attempts` counts claims, which is what
    -- admit_attempts_max bounds: a submission that kills every runner that touches it must end.
    runner_id        uuid        REFERENCES runners (id),
    claim_token      uuid,
    lease_expires_at timestamptz,
    attempts         int         NOT NULL DEFAULT 0,

    -- WHAT THE RUNNER FOUND, as it sent it: Orion's admission verdict and stats, and the probe's
    -- tally. Read only through admission_facts(), which types every value, because this is JSON a
    -- runner built and the clock binds parts of it into statements.
    report           jsonb,
    reported_at      timestamptz,

    -- Why the clock last sent a report back to the queue, for whoever reads the row.
    requeued_for     text,

    -- How many of those reports were a probe over the node's `models.max_probe_ms`. One is a runner
    -- that was busy; every attempt is the model. So a submission whose every attempt measured a
    -- slow probe expires PROBE_TOO_SLOW, and any other that runs out expires TIMED_OUT. LAST in the
    -- table on purpose: a database migrated by hand appends it, and a fresh build must agree.
    slow_probes      int         NOT NULL DEFAULT 0,

    CONSTRAINT admissions_attempts_nonneg CHECK (attempts >= 0),
    CONSTRAINT admissions_slow_probes_bounded CHECK (slow_probes BETWEEN 0 AND attempts)
);

-- The runner's claim: prepared rows nobody has reported on, oldest first.
CREATE INDEX admissions_queue_idx ON admissions (prepared_at) WHERE report IS NULL;

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
    -- THE RECORD, moved by the fold with matches_played: a win is first alone, a draw a shared
    -- first, anything else a loss (a disqualification included). A model's season page sums its
    -- versions' Open rows rather than re-reading every match they played.
    wins            int         NOT NULL DEFAULT 0,
    draws           int         NOT NULL DEFAULT 0,
    losses          int         NOT NULL DEFAULT 0,
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
    -- WHAT THE NAME SAYS, split by season_map_name(): `large-cave-4p-3h` is size `large`, terrain
    -- `cave`, and 3 hills a player -- which the upload checks against the file's own `hills`
    -- array (players x H entries). Soma keeps no list of sizes or terrains; the words are stored as
    -- given. NULLABLE, with no CHECK on the name: a board uploaded before the name rule keeps its
    -- row through a restore, and the upload refuses a name off the pattern instead.
    size        text,
    terrain     text,
    hills       smallint,     -- hills PER PLAYER, the name's `Hh`
    -- COUNTED MATCHES ON THIS BOARD, trials excluded, and the newest of them: moved by count's
    -- fold, so the maps page reads two columns rather than counting the season once per board.
    -- latest_match_id's foreign key is added after `matches`.
    matches          int      NOT NULL DEFAULT 0,
    latest_match_id  uuid,
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
    CONSTRAINT season_maps_board     CHECK (jsonb_typeof(board) = 'object'),
    CONSTRAINT season_maps_name_parts CHECK ((size IS NULL) = (terrain IS NULL)
                                             AND (size IS NULL) = (hills IS NULL)
                                             AND (hills IS NULL OR hills >= 1))
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

-- -------------------------------------------------------------- season rounds

-- A SEASON IN ROUNDS, AND ITS FINALS. A row is a scheduled reset: at `starts_at` the count clock
-- (the only writer of a ladder) raises every active version's Open sigma to `sigma_floor` and draws
-- its mu `mu_shrink` of the way to the season's mean, cancels the queue paired under the round
-- before, and stamps `applied_at`; from then on the round is the season's CURRENT one (the newest
-- applied row, season_round()), pair stamps it on every match it pairs and gives each active
-- version `games` rated matches in it, and the leaderboard counts them. Raising every sigma to one
-- floor gives an old version and a new one the same 3-sigma discount, which is what stops a
-- version's age being its score; `mu_shrink` 1 with the prior's sigma is a full reset.
--
-- Two kinds. `round`: the weekly ones the withdraw clock schedules from `rules.rounds`, and any an
-- admin adds by hand. `finals`: the admin's alone, only once the window has closed, with numbers
-- chosen then; `games` becomes a wall no entry passes, and the season closes when every entry has
-- played them. `warn_minutes` before the start the withdraw clock posts the countdown
-- (`announced_at`). An unapplied row may be edited or cancelled; nothing deletes one.
CREATE TABLE season_rounds (
    season_id    uuid        NOT NULL REFERENCES seasons (id),
    n            int         NOT NULL,
    kind         text        NOT NULL,
    starts_at    timestamptz NOT NULL,
    games        int         NOT NULL,
    sigma_floor  float8,
    mu_shrink    float8      NOT NULL DEFAULT 0,
    warn_minutes int         NOT NULL DEFAULT 15,
    created_by   uuid        REFERENCES users (id),   -- null: scheduled by the clock from the rules
    created_at   timestamptz NOT NULL DEFAULT now(),
    announced_at timestamptz,
    applied_at   timestamptz,
    cancelled_at timestamptz,
    PRIMARY KEY (season_id, n),
    CONSTRAINT season_rounds_n           CHECK (n >= 1),
    CONSTRAINT season_rounds_kind        CHECK (kind IN ('round', 'finals')),
    CONSTRAINT season_rounds_games       CHECK (games BETWEEN 1 AND 100000),
    CONSTRAINT season_rounds_sigma_floor CHECK (sigma_floor IS NULL OR sigma_floor > 0 AND sigma_floor <= 1000),
    CONSTRAINT season_rounds_mu_shrink   CHECK (mu_shrink BETWEEN 0 AND 1),
    CONSTRAINT season_rounds_warn        CHECK (warn_minutes BETWEEN 0 AND 1440),
    CONSTRAINT season_rounds_one_end     CHECK (applied_at IS NULL OR cancelled_at IS NULL)
);
-- One finals a season, and one round waiting at a time: an admin moves the waiting one rather than
-- stacking a second behind it, and the clock schedules the next only once it has started.
CREATE UNIQUE INDEX season_rounds_one_finals_uniq
    ON season_rounds (season_id) WHERE kind = 'finals' AND cancelled_at IS NULL;
CREATE UNIQUE INDEX season_rounds_one_waiting_uniq
    ON season_rounds (season_id) WHERE applied_at IS NULL AND cancelled_at IS NULL;

-- A ROUND'S NUMBERS AS AN ADMIN GIVES THEM, each optional here (the schedule requires `games`
-- itself): the one rule the schedule and edit writes and their `why` all ask, so a write and its
-- diagnosis cannot disagree about why a request failed. The table's CHECKs say the same.
CREATE FUNCTION season_round_numbers_ok(p_games float8, p_sigma_floor float8, p_mu_shrink float8,
                                        p_warn float8)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT (p_games IS NULL OR (p_games = trunc(p_games) AND p_games BETWEEN 1 AND 100000))
       AND (p_sigma_floor IS NULL OR (p_sigma_floor > 0 AND p_sigma_floor <= 1000))
       AND (p_mu_shrink IS NULL OR p_mu_shrink BETWEEN 0 AND 1)
       AND (p_warn IS NULL OR (p_warn = trunc(p_warn) AND p_warn BETWEEN 0 AND 1440));
$$;

-- THE SEASON'S CURRENT ROUND: the newest one applied, or NULL while it has none.
CREATE FUNCTION season_round(p_season uuid) RETURNS season_rounds LANGUAGE sql STABLE AS $$
    SELECT r.* FROM season_rounds r
     WHERE r.season_id = p_season AND r.applied_at IS NOT NULL
     ORDER BY r.n DESC LIMIT 1;
$$;

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
    -- THE ROUND IT WAS PAIRED IN (season_rounds.n), null for a trial or a season with no round. A
    -- round's games are the rated matches carrying its number, so a match paired before a reset
    -- and folded after it counts for the round it was played for and not the one it landed in.
    round                int,

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

    -- WHEN THE REFUSALS STARTED, and it is what `refusal_grace_secs` is measured from. The grace
    -- used to run from `created_at`, which made it the ROW's age rather than the FLEET's allowance
    -- to catch up -- so a runner coming up cold against a queue paired an hour ago refused each row
    -- and, the grace having long passed, failed it MODEL_UNAVAILABLE on the very first refusal.
    -- That is not a corner: it is every deployment where the fleet is replaced while work is
    -- queued, the release runbook's own step included. Anchored here, a fleet that has just
    -- arrived always gets the full window whatever the row's age, and a model that is genuinely
    -- gone still fails at the ceiling a grace later.
    --
    -- Null until the first refusal, which is the release statement's own coalesce, so the first
    -- refusal can never be the one that fails a row. Nothing clears it: a row that is refused, then
    -- played, is finished, and one that is refused in two bursts an hour apart is a fleet that
    -- could not serve it either time. A deployment that replaces its whole fleet clears the
    -- refusal state of what is still pending instead (scripts/cutover/backfill.sql), because those
    -- refusals were a fleet that no longer exists.
    first_refused_at     timestamptz,

    -- WHICH MACHINE HOLDS IT, written at claim. Not a security control -- a runner is operated by
    -- an admin -- but without it every operational question about the fleet is unanswerable: which
    -- machine played this match, and which machine is wedged. Null until a runner claims the
    -- row; a reaped row keeps the attribution of the attempt that lapsed.
    played_by            uuid         REFERENCES runners (id),

    -- ---- what Kalam reports
    reason               text,        -- free text, never an enum: game-defined
    turns                int,
    played_ms            int,
    engine_digest_played text,        -- what actually ran; compare with engine_digest for skew
    orion_version        text,        -- which Orion ran the adapters; a sweep is per upgrade (R10)
    replay_key           text,        -- names the attempt, so a stale attempt's blob is an orphan
    played_at            timestamptz,
    fault_reason         text,        -- LEASE_LAPSED (reap) or MODEL_UNAVAILABLE (release): the
                                      -- fleet's failure, never a seat's; a model's own is a strike
    closed_at            timestamptz,

    -- ---- what withdraw reports
    withdrawn_reason     text,
    successor_version_id uuid         REFERENCES model_versions (id),

    -- ---- what count reports
    rated_at             timestamptz,
    rated_seq            bigint,
    -- THE TWO SORT KEYS the match listing cannot compute per page, written by the statement that
    -- rates the row, from match_sort_keys(). `margin` is the winner's score minus
    -- the runner-up's, null for a shared first place; the trial verdicts write it too, since a
    -- promoted candidate's trial is public. `upset` is the fold's alone: it is read off the Open
    -- ladder, and a trial feeds no ladder.
    margin               int,
    upset                float8,

    -- WHETHER ANYONE MAY SEE IT, as a column: match_public() is `m.listed` AND the match's season is
    -- PUBLIC (N30/V5), so the partial index on `listed` still proves the anonymous listing's own
    -- predicate and the season gate filters a private season's rows out of a by-id fetch too. Set by
    -- the statement that makes it so: finish, for a match with no trial, and a trial's `pass`, whose
    -- candidate goes public in the same statement. A trial in progress or a rejected candidate's
    -- never is. Nothing unsets it.
    listed               boolean      NOT NULL DEFAULT false,

    CONSTRAINT matches_seat_count         CHECK (seat_count >= 2),
    CONSTRAINT matches_listed_played      CHECK (NOT listed OR status IN ('finished', 'rated')),
    CONSTRAINT matches_strike_ceiling     CHECK (strike_ceiling > 0),
    CONSTRAINT matches_lapses_bounded     CHECK (lapses BETWEEN 0 AND 3),
    CONSTRAINT matches_round_fkey         FOREIGN KEY (season_id, round) REFERENCES season_rounds (season_id, n),
    CONSTRAINT matches_trial_no_round     CHECK (trial_version_id IS NULL OR round IS NULL),

    -- The status and the columns that go with it cannot disagree. This is also half of what
    -- confines a runner: `runner_gate` holds UPDATE on the match player's columns only, so there is
    -- no state it can reach that is not one of its own -- it cannot mark a row 'rated', because it
    -- cannot write rated_at.
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

ALTER TABLE season_maps
    ADD CONSTRAINT season_maps_latest_match_fkey FOREIGN KEY (latest_match_id) REFERENCES matches (id);

-- THE TERMS A MATCH IS PLAYED UNDER, from the row's own season: coalesce(season rule, the game's
-- manifest limits, the deployment's [vars]), which the claim's `row` read sends to the runner as the
-- execution contract and the claim's `pick` uses to hand a row only to a runner that can finish it.
-- One function, so the two statements cannot disagree about what a match will cost.
-- THE TERMS A SEASON'S MATCHES ARE PLAYED UNDER, from the season alone: what `match_execution`
-- answers for a row that does not exist yet. PAIR NEEDS IT BEFORE THERE IS A MATCH -- it prices a
-- BOARD against the fleet to decide whether a row on it could ever be claimed -- and the gate needs
-- it for a row in hand, so the coalesce order (season rule, game limits, deploy var) is written
-- once here and `match_execution` delegates. A second copy of it in a workflow is how the queue and
-- the claim come to disagree about what a match costs.
CREATE FUNCTION season_execution(p_season uuid, turn_ms_default int, max_turns_default int,
                                 refusal_default int)
RETURNS TABLE (turn_ms int, max_turns int, refusal_ceiling int)
LANGUAGE sql STABLE AS $$
    SELECT coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean
                         THEN (se.rules -> 'execution' ->> 'turn_ms')::int END,
                    (g.manifest -> 'limits' ->> 'turn_ms')::int, turn_ms_default),
           coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean
                         THEN (se.rules -> 'execution' ->> 'max_turns')::int END,
                    (g.manifest -> 'limits' ->> 'max_turns')::int, max_turns_default),
           coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean
                         THEN (se.rules -> 'execution' ->> 'refusal_ceiling')::int END,
                    refusal_default)
      FROM seasons se JOIN games g ON g.id = se.game_id
     WHERE se.id = p_season
$$;

CREATE FUNCTION match_execution(m matches, turn_ms_default int, max_turns_default int, refusal_default int)
RETURNS TABLE (turn_ms int, max_turns int, refusal_ceiling int)
LANGUAGE sql STABLE AS $$
    SELECT e.turn_ms, e.max_turns, e.refusal_ceiling
      FROM season_execution(m.season_id, turn_ms_default, max_turns_default, refusal_default) e
$$;

-- CAN ANY LIVE RUNNER FINISH A MATCH OF `p_seats` SEATS IN THIS SEASON? The gate's fit, asked of the
-- fleet instead of one runner: turn_ms x max_turns x the seat batches, plus a tenth. Pair asks it of
-- every enabled board before choosing one, because a row on a board NO runner can hold is pending
-- for ever -- the reap only touches `claimed` and `running` -- and once `pair_depth_target` of them
-- have piled up the season stops pairing anything at all, silently: the claim answers `{"idle":
-- true}` and nothing says why. The fleet policy is read exactly as the claim reads it, so the two
-- cannot disagree about who could take the row.
-- A COLD FLEET IS NOT A REFUSAL. With no live runner at all this answers true, so pair queues ahead
-- of the fleet exactly as it always has: the rows wait, pending and visible, and are claimed when a
-- runner arrives. The question here is only whether a board is one the runners that ARE up could
-- never hold -- an answer nothing can give while none is up.
CREATE FUNCTION seats_claimable(p_season uuid, p_seats int,
                                turn_ms_default int, max_turns_default int)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    WITH fleet AS (
        SELECT lr.match_timeout_ms, lr.seat_concurrency
          FROM live_runners lr
          JOIN runners r  ON r.id = lr.id
          JOIN seasons se ON se.id = p_season
         WHERE r.plays_matches
           AND r.engine_digest = se.engine_digest
           AND r.last_seen_at > now() - runner_live_window()
           AND CASE WHEN lr.season_id IS NOT NULL
                    THEN lr.season_id = se.id AND (se.fleet ->> 'matches') IN ('own', 'both')
                    ELSE (se.fleet ->> 'matches') IN ('platform', 'both') END
    )
    SELECT NOT EXISTS (SELECT 1 FROM fleet)
        OR EXISTS (
            SELECT 1
              FROM fleet f
              CROSS JOIN LATERAL season_execution(p_season, turn_ms_default, max_turns_default, 5) e
             -- The same inequality as soma-gate-claim's `pick`, and unbounded for a runner that has
             -- reported neither number, exactly as there.
             WHERE f.match_timeout_ms IS NULL OR f.seat_concurrency IS NULL
                OR e.turn_ms::numeric * e.max_turns * ceil(p_seats::numeric / f.seat_concurrency) * 11
                   <= f.match_timeout_ms::numeric * 10)
$$;

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

-- --------------------------------------------------------------- match_frames

-- A MATCH'S LAST FRAME, AS THE RUNNER SENT IT AT FINISH: what a card rests on. A replay stores each
-- turn's actions and no state, so the state at the last turn exists only where the match ended --
-- on the runner -- and is sent once, in the finish body. OPAQUE: Soma stores it as given and never
-- reads inside it, because game state is the cartridge's. The frame is not only what moved: it
-- carries the water too, about 5 KB of a 7 KB frame.
--
-- lz4 rather than pglz: a frame is written once and read by every card that shows it.
--
-- Its own table so the match row, which claim, renew and finish update in a loop, stays small. The
-- size CHECK is a backstop: finish writes no frame over it rather than failing the match, because
-- a card on turn zero is a better outcome than a result lost for want of a picture.
CREATE TABLE match_frames (
    match_id    uuid        PRIMARY KEY REFERENCES matches (id),
    turn        int         NOT NULL,
    frame       jsonb       COMPRESSION lz4 NOT NULL,
    CONSTRAINT match_frames_turn_nonneg CHECK (turn >= 0),
    CONSTRAINT match_frames_frame_shape CHECK (jsonb_typeof(frame) = 'object'
                                               AND octet_length(frame::text) <= 65536)
);

-- -------------------------------------------------------------- season_podium

-- THE PODIUM, FROZEN WHEN THE SEASON CLOSES: first to third on each ladder, written by withdraw's
-- close from podium_of() in the same statement that closes the season. The leaderboard's podium,
-- a profile's medals and the champions read these rows rather than re-rank every closed ladder on
-- every profile view. One place per owner (their best version stands for them) and no baselines:
-- the second unique below is that rule as an index.
CREATE TABLE season_podium (
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    ladder      ladder      NOT NULL,
    place       smallint    NOT NULL,
    version_id  uuid        NOT NULL REFERENCES model_versions (id),
    owner_id    uuid        NOT NULL REFERENCES users (id),
    rating      float8      NOT NULL,     -- the conservative rating it closed on
    PRIMARY KEY (season_id, ladder, place),
    UNIQUE (season_id, ladder, owner_id),
    CONSTRAINT season_podium_place CHECK (place BETWEEN 1 AND 3)
);
CREATE INDEX season_podium_owner_idx ON season_podium (owner_id);

-- ------------------------------------------------------------------ community
--
-- Comments, stories, posts, announcements, picks: everything a person writes for others to read.
-- SOFT DELETE THROUGHOUT -- soma-db refuses DELETE -- so deleting, removing, unpinning, taking a
-- word off the list and disabling an announcement each set a state or a timestamp.

-- THE TEXT RULES, one function each, asked by the table's CHECK, the write's WHERE and the `why`
-- that explains a refusal -- so the three cannot disagree about what a text may be.
--
-- One line: not blank, at most `n` characters, no line break.
CREATE FUNCTION line_ok(t text, n int) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(btrim(t) <> '' AND char_length(t) <= n AND position(E'\n' IN t) = 0, false);
$$;

-- A link inside the site: a path, never `//host` (which a browser reads as another origin).
CREATE FUNCTION site_path_ok(l text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(left(l, 1) = '/' AND left(l, 2) <> '//' AND char_length(l) <= 500, false);
$$;

-- A link an admin may publish on an announcement: a site path, or an https:// URL.
CREATE FUNCTION link_ok(l text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(site_path_ok(l) OR (char_length(l) <= 500 AND l ~ '^https://[^/\s]+'), false);
$$;

-- A slug: lower-case words joined by single hyphens.
CREATE FUNCTION slug_ok(t text, n int) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(t ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(t) <= n, false);
$$;

-- A listed word: letters, digits and single spaces, hyphens or apostrophes between them, lower
-- case -- none of which is special in a regular expression, so text_hold_tag needs no escaping.
CREATE FUNCTION comment_word_ok(w text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(w = lower(w) AND char_length(w) <= 40 AND w ~ '^[[:alnum:]]+([ ''-][[:alnum:]]+)*$', false);
$$;

-- A uuid out of caller text, or NULL for anything else -- never a 22P02 on a request path.
CREATE FUNCTION try_uuid(t text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN t::uuid END;
$$;

-- `try_uuid`'s siblings, for the other halves of a keyset cursor. A CURSOR IS CALLER TEXT: it is
-- handed back to us in a query string, and anyone may type anything into one. A bare
-- `split_part(cursor, '|', 1)::timestamptz` on a public listing turns `?cursor=x` into a 22007 and
-- an UNAUTHENTICATED 500 -- on `/v1/matches`, the site's main listing. Every cursor half now casts
-- through one of these and reads as "no cursor" instead, which is the first page: wrong input gives
-- the caller the start of the list, not an error page and a trace row.
--
-- plpgsql with an EXCEPTION block rather than a regex, because neither timestamptz nor float8 has
-- one worth writing; the block costs a subtransaction, and a cursor is parsed once per request.
-- timestamptz parsing reads the session TimeZone, so it is STABLE where the other two are IMMUTABLE.
CREATE FUNCTION try_timestamptz(t text) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN t::timestamptz; EXCEPTION WHEN others THEN RETURN NULL; END;
$$;

CREATE FUNCTION try_int(t text) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN t::int; EXCEPTION WHEN others THEN RETURN NULL; END;
$$;

CREATE FUNCTION try_float8(t text) RETURNS float8 LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN t::float8; EXCEPTION WHEN others THEN RETURN NULL; END;
$$;

-- The uuids in a caller's JSON array, the rest dropped; nothing for anything but an array.
CREATE FUNCTION jsonb_uuids(j jsonb) RETURNS SETOF uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT u FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(j) = 'array' THEN j ELSE '[]'::jsonb END) x,
                  LATERAL try_uuid(x) u
     WHERE u IS NOT NULL;
$$;

-- The words that hold a comment or a story and refuse a bio or a note. A word is matched whole and
-- case-insensitively; it may be a phrase ("dm me"), shaped by comment_word_ok(). A change applies
-- to the next text, never to the ones already through.
CREATE TABLE comment_words (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    word        text        NOT NULL,
    added_by    uuid        NOT NULL REFERENCES users (id),
    added_at    timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz,
    removed_by  uuid        REFERENCES users (id),
    CONSTRAINT comment_words_shape CHECK (comment_word_ok(word)),
    CONSTRAINT comment_words_removed CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
CREATE UNIQUE INDEX comment_words_live_uniq ON comment_words (word) WHERE removed_at IS NULL;

-- WHY A TEXT IS HELD OR REFUSED, or null when it is not: the first listed word it contains, else
-- `link` when links count (p_links) and it carries one. Comments, stories, bios and notes all ask
-- this, so every route holds or refuses a text for the same reason. Postgres has the regex
-- datalogic lacks. A link holds a comment and not a story, whose normal content links are.
--
-- ONE REGEX FOR THE WHOLE LIST FIRST, a word at a time only on a hit to name it. Postgres caches
-- 32 compiled regexes, so a pattern per word recompiles every word for every text once the list
-- is longer than that; the alternation is one pattern, the same string until the list changes.
CREATE FUNCTION text_hold_tag(p_body text, p_links boolean) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        CASE WHEN p_body ~* (SELECT '\m(' || string_agg(w.word, '|' ORDER BY w.word) || ')\M'
                               FROM comment_words w WHERE w.removed_at IS NULL)
             THEN (SELECT w.word FROM comment_words w
                    WHERE w.removed_at IS NULL AND p_body ~* ('\m' || w.word || '\M')
                    ORDER BY w.word LIMIT 1) END,
        CASE WHEN p_links AND p_body ~* ('(https?://|\mwww\.|\m[[:alnum:]-]+\.'
                                         || '(com|net|org|io|dev|gg|co|xyz|ru|cn|info|biz|me|app|ly|tk|to)\M)')
             THEN 'link' END);
$$;

-- ONE THREAD PER HOST, a match or a model, made on its first comment or lock. It holds the lock and
-- the count so a comment never updates the match row that claim, renew and finish update in a
-- loop. `comments` counts LIVE comments -- what a card and the Most discussed sort print -- and is
-- moved by each comment write in its own statement.
CREATE TABLE threads (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id    uuid        UNIQUE REFERENCES matches (id),
    model_id    uuid        UNIQUE REFERENCES models (id),
    comments    int         NOT NULL DEFAULT 0,
    locked_at   timestamptz,
    locked_by   uuid        REFERENCES users (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT threads_one_host      CHECK (num_nonnulls(match_id, model_id) = 1),
    CONSTRAINT threads_lock_whole    CHECK ((locked_at IS NULL) = (locked_by IS NULL)),
    CONSTRAINT threads_count_nonneg  CHECK (comments >= 0)
);

-- One row per comment. `root_id` is the top-level comment a reply hangs under, and a top-level
-- comment's own id, so "twenty threads with their replies" is one indexed read. The composite keys
-- hold a parent and a root to the same thread as the reply.
--
--   live     -- public
--   held     -- tagged by text_hold_tag; its author sees it, nobody else does until an admin decides
--   removed  -- an admin's; restorable
--   deleted  -- its author's
--
-- A removed or deleted comment with replies is kept as a placeholder by comment_json().
CREATE TABLE comments (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id   uuid        NOT NULL REFERENCES threads (id),
    parent_id   uuid,
    root_id     uuid        NOT NULL,
    author_id   uuid        NOT NULL REFERENCES users (id),
    body        text        NOT NULL,
    state       text        NOT NULL DEFAULT 'live',
    hold_tag    text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    decided_at  timestamptz,
    decided_by  uuid        REFERENCES users (id),
    UNIQUE (id, thread_id),
    FOREIGN KEY (parent_id, thread_id) REFERENCES comments (id, thread_id),
    FOREIGN KEY (root_id, thread_id)   REFERENCES comments (id, thread_id),
    CONSTRAINT comments_state      CHECK (state IN ('live', 'held', 'removed', 'deleted')),
    CONSTRAINT comments_body_shape CHECK (line_ok(body, 500)),
    CONSTRAINT comments_root_shape CHECK ((parent_id IS NULL) = (root_id = id)),
    CONSTRAINT comments_held_tag   CHECK (state <> 'held' OR hold_tag IS NOT NULL),
    CONSTRAINT comments_decided    CHECK ((decided_at IS NULL) = (decided_by IS NULL))
);
CREATE INDEX comments_thread_idx ON comments (thread_id, root_id, created_at);
CREATE INDEX comments_author_idx ON comments (author_id, created_at DESC);
CREATE INDEX comments_held_idx   ON comments (created_at) WHERE state = 'held';
-- Most discussed: live comments in a `since` window, counted per thread, from the index alone.
CREATE INDEX comments_live_recent_idx ON comments (created_at, thread_id) WHERE state = 'live';
-- The admin desk's All tab, newest first across every state, with a keyset cursor.
CREATE INDEX comments_recent_idx ON comments (created_at DESC, id DESC);
-- A thread's page of top-level comments, newest first, off the index however long the thread.
CREATE INDEX comments_thread_roots_idx ON comments (thread_id, created_at DESC, id DESC) WHERE parent_id IS NULL;

-- A reader's flag on a comment: one per reader per comment, both halves optional.
CREATE TABLE comment_reports (
    comment_id  uuid        NOT NULL REFERENCES comments (id),
    reporter_id uuid        NOT NULL REFERENCES users (id),
    reason      text,
    words       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (comment_id, reporter_id),
    CONSTRAINT comment_reports_reason CHECK (reason IS NULL
                                             OR reason IN ('spam', 'abuse', 'off_topic', 'other')),
    CONSTRAINT comment_reports_words  CHECK (words IS NULL
                                             OR (btrim(words) <> '' AND char_length(words) <= 200))
);
CREATE INDEX comment_reports_reporter_idx ON comment_reports (reporter_id, created_at DESC);

-- A MODEL'S STORY, one per model, written by its owner. The public reads `title` and `body`, the
-- approved text; an edit that trips the word list waits in `pending_*` with its tag, and the owner
-- reads it through their own route while the public keeps the approved text. A clean edit
-- replaces the approved text at once. Text only: headings, links and lists, no picture.
CREATE TABLE model_stories (
    model_id      uuid        PRIMARY KEY REFERENCES models (id),
    title         text,
    body          text,
    pending_title text,
    pending_body  text,
    hold_tag      text,
    featured_at   timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    approved_at   timestamptz,
    removed_at    timestamptz,
    CONSTRAINT model_stories_title_size CHECK (title IS NULL OR line_ok(title, 80)),
    CONSTRAINT model_stories_pending_title_size CHECK (pending_title IS NULL OR line_ok(pending_title, 80)),
    CONSTRAINT model_stories_body_size  CHECK (body IS NULL OR char_length(body) <= 20000),
    CONSTRAINT model_stories_pending_body_size CHECK (pending_body IS NULL OR char_length(pending_body) <= 20000),
    CONSTRAINT model_stories_held       CHECK ((pending_body IS NULL) = (hold_tag IS NULL))
);
CREATE INDEX model_stories_featured_idx ON model_stories (featured_at DESC) WHERE featured_at IS NOT NULL;

-- THE TEAM'S POSTS. Keyed by id, so the slug stays editable until and after publishing; unique
-- while it is anyone's. A draft has no published_at, and unpublishing clears it.
CREATE TABLE posts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         text        NOT NULL UNIQUE,
    title        text        NOT NULL,
    author_id    uuid        NOT NULL REFERENCES users (id),
    body         text        NOT NULL DEFAULT '',
    published_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT posts_slug_shape  CHECK (slug_ok(slug, 80)),
    CONSTRAINT posts_title_shape CHECK (line_ok(title, 120)),
    CONSTRAINT posts_body_size   CHECK (char_length(body) <= 100000)
);
CREATE INDEX posts_published_idx ON posts (published_at DESC, id DESC) WHERE published_at IS NOT NULL;

-- A LINE ACROSS EVERY PAGE. Live while not disabled and not past `ends_at`. Its link is a site path
-- or an https:// URL: only an admin writes one. (Notify keeps the site-path rule, since each send
-- becomes a notifications row.)
--
-- THE CLOCK WRITES ONE TOO: a season round's countdown ("Scores reset in 14 min"). That row names
-- its `season_id`, the instant it counts down to (`at`, which web draws as a live countdown so the
-- words never go stale), and a `source` naming the round, unique, which is what makes the withdraw
-- clock's post idempotent; it has no publisher and ends at `at`.
CREATE TABLE announcements (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         text        NOT NULL,
    body         text        NOT NULL,
    link         text,
    dismissable  boolean     NOT NULL DEFAULT true,
    ends_at      timestamptz,
    season_id    uuid        REFERENCES seasons (id),
    at           timestamptz,
    source       text        UNIQUE,
    published_by uuid        REFERENCES users (id),
    published_at timestamptz NOT NULL DEFAULT now(),
    disabled_at  timestamptz,
    disabled_by  uuid        REFERENCES users (id),
    CONSTRAINT announcements_kind      CHECK (kind IN ('notice', 'season', 'maintenance', 'incident')),
    CONSTRAINT announcements_body      CHECK (line_ok(body, 200)),
    CONSTRAINT announcements_link      CHECK (link IS NULL OR link_ok(link)),
    CONSTRAINT announcements_disabled  CHECK ((disabled_at IS NULL) = (disabled_by IS NULL)),
    CONSTRAINT announcements_publisher CHECK (published_by IS NOT NULL OR source IS NOT NULL)
);
CREATE INDEX announcements_live_idx ON announcements (published_at DESC) WHERE disabled_at IS NULL;

-- ONE ADMIN SEND to an audience. Each recipient gets a notifications row keyed `notify:<id>`, in
-- the one INSERT ... SELECT that writes this row's count; `audience` is the chips as chosen.
CREATE TABLE notify_sends (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    subject     text        NOT NULL,
    link        text,
    audience    jsonb       NOT NULL,
    sent_by     uuid        NOT NULL REFERENCES users (id),
    sent_at     timestamptz NOT NULL DEFAULT now(),
    recipients  int         NOT NULL DEFAULT 0,
    CONSTRAINT notify_sends_subject  CHECK (line_ok(subject, 200)),
    CONSTRAINT notify_sends_link     CHECK (link IS NULL OR site_path_ok(link)),
    CONSTRAINT notify_sends_audience CHECK (jsonb_typeof(audience) = 'object'),
    CONSTRAINT notify_sends_count    CHECK (recipients >= 0)
);
CREATE INDEX notify_sends_sent_idx ON notify_sends (sent_at DESC);

-- STAFF PICKS: matches an admin pinned, in order, until unpinned. A pick names a public match only
-- (match_public), which the pin checks.
CREATE TABLE picks (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id    uuid        NOT NULL REFERENCES matches (id),
    position    int         NOT NULL,
    pinned_by   uuid        NOT NULL REFERENCES users (id),
    pinned_at   timestamptz NOT NULL DEFAULT now(),
    unpinned_at timestamptz,
    unpinned_by uuid        REFERENCES users (id),
    CONSTRAINT picks_unpinned CHECK ((unpinned_at IS NULL) = (unpinned_by IS NULL))
);
CREATE UNIQUE INDEX picks_live_uniq ON picks (match_id) WHERE unpinned_at IS NULL;

-- ------------------------------------------------------------------ audit_log

-- EVERY ADMIN WRITE, written inside that write's own statement as a data-modifying CTE, so an
-- action and its line cannot disagree. `action` is `<thing>.<verb>` (`season.create`,
-- `comment.remove`); `target_id` is text because a season and a board are addressed by slug.
-- season_map_events and baseline_events stay: pairing reads them, and this table is for people.
CREATE TABLE audit_log (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id    uuid        NOT NULL REFERENCES users (id),
    action      text        NOT NULL,
    target_kind text        NOT NULL,
    target_id   text,
    reason      text,
    detail      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    -- THE SEASON A LINE IS ABOUT, so a season's admins read their own season's lines (S7). Filled
    -- by audit_log_season() below from the line itself, never by a writer, so no audit insert has
    -- to remember it: a `season` line's slug, the `season` a map's, baseline's or key's detail
    -- names, a season key's or runner's own season. Null for the platform's own lines.
    season_id   uuid        REFERENCES seasons (id),
    CONSTRAINT audit_log_action CHECK (action ~ '^[a-z_]+\.[a-z_]+$'),
    CONSTRAINT audit_log_kind   CHECK (target_kind ~ '^[a-z_]+$'),
    CONSTRAINT audit_log_reason CHECK (reason IS NULL OR char_length(reason) <= 300),
    CONSTRAINT audit_log_detail CHECK (jsonb_typeof(detail) = 'object')
);
CREATE INDEX audit_log_at_idx    ON audit_log (at DESC);
-- One season's lines, newest first: the season admin's audit page.
CREATE INDEX audit_log_season_idx ON audit_log (season_id, at DESC, id DESC) WHERE season_id IS NOT NULL;
-- THE SEASON OF A LINE, derived as the line is written (see audit_log.season_id). A slug is unique per
-- game, so the game the detail names narrows it; the newest season wins only if it names none.
CREATE FUNCTION audit_log_season() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.season_id IS NULL THEN
        NEW.season_id := coalesce(
            (SELECT s.id FROM seasons s JOIN games g ON g.id = s.game_id
              WHERE s.slug = coalesce(NEW.detail ->> 'season',
                                      CASE WHEN NEW.target_kind = 'season' THEN NEW.target_id END)
                AND (NEW.detail ->> 'game' IS NULL OR g.slug = NEW.detail ->> 'game')
              ORDER BY s.number DESC LIMIT 1),
            CASE WHEN NEW.target_kind = 'runner_key'
                 THEN (SELECT k.season_id FROM runner_keys k WHERE k.id = try_uuid(NEW.target_id)) END,
            CASE WHEN NEW.target_kind = 'runner'
                 THEN (SELECT k.season_id FROM runners r JOIN runner_keys k ON k.id = r.key_id
                        WHERE r.id = try_uuid(NEW.target_id)) END);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER audit_log_season BEFORE INSERT ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_season();
CREATE INDEX audit_log_admin_idx ON audit_log (admin_id, at DESC);
-- The lines naming one thing -- a user's desk reads its user's.
CREATE INDEX audit_log_target_idx ON audit_log (target_kind, target_id, at DESC);

-- --------------------------------------------------------------- watch_events

-- WHAT PEOPLE WATCH, counted per day and never per person: no user, no address. `visit` is one
-- page load and names no match; `opened` names how the viewer got there; `finished` is a replay
-- watched to its end. Upserted `n = n + 1` on the key, which treats a null match and a null `via`
-- as values (NULLS NOT DISTINCT, PostgreSQL 15+).
--
-- SHARDED: the writer picks `shard` at random (0-15) and a reader sums over it. Every page load's
-- `visit` is the same key for a whole day, and one row would queue every visit on one row lock.
CREATE TABLE watch_events (
    match_id    uuid        REFERENCES matches (id),
    day         date        NOT NULL,
    event       text        NOT NULL,
    via         text,
    shard       smallint    NOT NULL DEFAULT 0,
    n           bigint      NOT NULL DEFAULT 1,
    CONSTRAINT watch_events_key   UNIQUE NULLS NOT DISTINCT (match_id, day, event, via, shard),
    CONSTRAINT watch_events_shard CHECK (shard BETWEEN 0 AND 15),
    CONSTRAINT watch_events_event CHECK (event IN ('visit', 'opened', 'finished')),
    CONSTRAINT watch_events_match CHECK ((event = 'visit') = (match_id IS NULL)),
    CONSTRAINT watch_events_via   CHECK (CASE WHEN event = 'opened'
                                              THEN via IN ('tv', 'shelf', 'grid', 'next', 'rail', 'link')
                                              ELSE via IS NULL END),
    CONSTRAINT watch_events_n     CHECK (n >= 1)
);
CREATE INDEX watch_events_day_idx ON watch_events (day);

-- ----------------------------------------------------------- ladder_snapshots

-- THE FIELD ON EACH LADDER, ON THE HOUR: ladder_at() at the top of every hour a season is live,
-- written by the withdraw clock's first tick in that hour. `version_ids` is the field in rank order
-- and `ratings` each one's conservative rating, so a rank is an array position. The rating series
-- and a model's "rank a week ago" read these rows, whose number grows with hours and not with
-- matches; ladder_at() over the whole event history at every point of a series does not scale.
-- An hour with nobody standing is an empty snapshot, not a missing one.
CREATE TABLE ladder_snapshots (
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    ladder      ladder      NOT NULL,
    at          timestamptz NOT NULL,
    version_ids uuid[]      NOT NULL,
    ratings     real[]      NOT NULL,
    PRIMARY KEY (season_id, ladder, at),
    CONSTRAINT ladder_snapshots_hour  CHECK (at = date_trunc('hour', at)),
    CONSTRAINT ladder_snapshots_shape CHECK (cardinality(version_ids) = cardinality(ratings))
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

-- At most one submission in flight PER ENTRY PER SEASON (N30), spanning both pre-active states: an
-- entry with a verified version waiting for its trial may not take another release IN THE SAME
-- SEASON -- but a student may have a version in admission in class and another in public at once,
-- which is why season_id is in the key. The per-USER ceiling ACROSS entries is entries.in_flight_max
-- and is deliberately not here -- an index that says "one" and a count that says "one" are two rules
-- that will one day say different numbers.
CREATE UNIQUE INDEX model_versions_one_in_flight_uniq
    ON model_versions (model_id, season_id) WHERE status IN ('testing', 'verified');

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

-- The public match listing. Partial on `listed`, which match_public() is, so the listing's own
-- predicate proves the index. The trailing id makes the keyset cursor total: two matches can
-- share a played_at to the microsecond, and a page boundary that is not total repeats or skips.
CREATE INDEX matches_season_played_idx
    ON matches (season_id, played_at DESC, id DESC)
    WHERE listed;

-- The listing's three stored sorts: closest, biggest upset, longest, over the season's public
-- matches that are not trials -- the season listing's own predicate, so each sort reads its first
-- page off the index. A promoted trial reaches a sort through a model's listing, which is small.
CREATE INDEX matches_season_margin_idx
    ON matches (season_id, margin, id)
    WHERE listed AND trial_version_id IS NULL;
CREATE INDEX matches_season_upset_idx
    ON matches (season_id, upset DESC, id DESC)
    WHERE listed AND trial_version_id IS NULL;
CREATE INDEX matches_season_turns_idx
    ON matches (season_id, turns DESC, id DESC)
    WHERE listed AND trial_version_id IS NULL;

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

-- A round's games: pair's demand, the finals' close and the leaderboard count them per version.
CREATE INDEX matches_season_round_idx
    ON matches (season_id, round) WHERE round IS NOT NULL;

-- EACH VERSION'S RATED GAMES IN ONE ROUND of a season: the rated matches pair stamped with it. One
-- function, so pair's quota, the finals' close, the leaderboard and the admin's progress count the
-- same thing.
CREATE FUNCTION round_games(p_season uuid, p_round int)
RETURNS TABLE (version_id uuid, games bigint) LANGUAGE sql STABLE AS $$
    SELECT s.version_id, count(*)
      FROM matches m JOIN match_seats s ON s.match_id = m.id
     WHERE m.season_id = p_season AND m.round = p_round AND m.status = 'rated'
     GROUP BY s.version_id;
$$;

-- WHERE A SEASON'S FINALS STAND: null with none (or one cancelled), else how many entries are in
-- them, how many have played their games, and whether they are done -- started, and every active
-- entry at its number. Baselines are not entries: they fill the last seats and are never waited for,
-- and neither is a retired entry, which pair no longer seats.
CREATE FUNCTION season_finals(p_season uuid)
RETURNS TABLE (n int, games int, starts_at timestamptz, applied boolean,
               entries bigint, complete bigint, done boolean)
LANGUAGE sql STABLE AS $$
    SELECT r.n, r.games, r.starts_at, r.applied_at IS NOT NULL,
           count(v.id), count(v.id) FILTER (WHERE coalesce(g.games, 0) >= r.games),
           r.applied_at IS NOT NULL AND count(v.id) FILTER (WHERE coalesce(g.games, 0) < r.games) = 0
      FROM season_rounds r
      LEFT JOIN model_versions v ON v.season_id = r.season_id AND v.status = 'active'
                                AND NOT EXISTS (SELECT 1 FROM models e JOIN users u ON u.id = e.owner_id
                                                 WHERE e.id = v.model_id
                                                   AND (u.role = 'baseline' OR e.retired_at IS NOT NULL))
      LEFT JOIN round_games(r.season_id, r.n) g ON g.version_id = v.id
     WHERE r.season_id = p_season AND r.kind = 'finals' AND r.cancelled_at IS NULL
     GROUP BY r.n, r.games, r.starts_at, r.applied_at;
$$;

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

-- A version's rating AT AN INSTANT: ladder_at() reads the last event at or before t, per version,
-- for every edge of a series.
CREATE INDEX rating_events_at_idx
    ON rating_events (version_id, ladder, created_at);

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

-- THE SEASON A GAME IS READ THROUGH WHEN NONE IS NAMED -- the FEATURED season (N30). With `?season=`
-- (p_slug) it is that slug, whatever its state or visibility (the caller named it; a visibility gate
-- is the reader's, not this function's). Without one it is games.featured_season_id if the admin has
-- set a PUBLIC one, else the newest live public season, else the newest public season -- a private
-- season is never the featured fallback, so a game with only private seasons resolves to nothing and
-- is unlisted (G2). The signature is unchanged, so the six routes that resolve a season this way and
-- the seventh that pins the slug are untouched.
CREATE FUNCTION current_season(p_game uuid, p_slug text DEFAULT NULL)
RETURNS SETOF seasons LANGUAGE sql STABLE AS $$
    SELECT s.* FROM seasons s
     JOIN games g ON g.id = s.game_id
     WHERE s.game_id = p_game
       AND ((p_slug IS NOT NULL AND s.slug = p_slug)
         OR (p_slug IS NULL AND s.visibility = 'public'))
     -- With a slug there is one match and the ordering is moot. Without one, the featured public
     -- season wins; failing that, the newest live public, then the newest public.
     ORDER BY (g.featured_season_id = s.id) DESC,
              (s.closed_at IS NULL) DESC,
              s.number DESC
     LIMIT 1;
$$;

-- THE SAME RESOLUTION, BUT PUBLIC ONLY (N30). The anonymous, path-cached public reads resolve a
-- season through this: a private season named by `?season=<slug>` returns NOTHING here, so every
-- public read answers as for a season that does not exist (V2) -- the security half of visibility,
-- and it stays cacheable because the answer does not depend on a viewer. A member seeing their own
-- private season's standings is the viewer-aware half (Phase 4b, the CACHE.md decision), which is not
-- this. current_season() (visibility-blind on a named slug) stays what the submission path and the
-- season-scoped user routes resolve through, because a member DOES name their private season there.
CREATE FUNCTION public_season(p_game uuid, p_slug text DEFAULT NULL)
RETURNS SETOF seasons LANGUAGE sql STABLE AS $$
    SELECT s.* FROM seasons s
     JOIN games g ON g.id = s.game_id
     WHERE s.game_id = p_game AND s.visibility = 'public'
       AND (p_slug IS NULL OR s.slug = p_slug)
     ORDER BY (g.featured_season_id = s.id) DESC,
              (s.closed_at IS NULL) DESC,
              s.number DESC
     LIMIT 1;
$$;

-- WHAT OF THE RULES A SEASON MAY SHOW THE WORLD. season_json() is returned by six public routes.
-- Since N30 the participant list lives in season_participants, not in `rules`, so there is nothing in
-- the document left to hide: the rules a season declares are the contest a competitor is entering,
-- and this returns them whole.
CREATE FUNCTION season_rules_public(r jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT r;
$$;

-- The season object every route returns. The counts are the ones the site prints, and they are
-- different questions: `entries` is how many models are in the field, `active_versions` the
-- ladder's size, `entered_versions` everything ever submitted, `in_flight_versions` what "18
-- versions are mid-trial" means. `matches_played` EXCLUDES TRIALS so it agrees with what
-- GET /v1/matches can reach, and is the column count's fold moves: RATED matches, so one finished
-- a moment ago is counted within the minute.
CREATE FUNCTION season_json(s seasons) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'name',   s.name,
        'slug',   s.slug,
        'state',  season_state(s),
        'submissions_open_at',  s.submissions_open_at,
        'submissions_close_at', s.submissions_close_at,
        'closed_at',            s.closed_at,
        'close_requested_at',   s.close_requested_at,
        -- Who may see it and who may enter (N30): `public`/`private` and `open`/`restricted`. Safe to
        -- return -- the route that carries this object already gates who receives it at all (a private
        -- season answers as nonexistent to a stranger) -- and web draws a cohort badge from them. The
        -- fleet policy and providers are admin-facing and are not here; the fleet route returns fleet.
        'visibility',           s.visibility,
        'entry',                s.entry,
        'engine_digest',        s.engine_digest,
        'rules',                season_rules_public(s.rules),
        -- The caps this season is played under: they are per season, and a standing cannot be read
        -- without them.
        'weight_classes',       weight_classes_public(s.weight_classes),
        'entries',            (SELECT count(DISTINCT v.model_id) FROM model_versions v
                               WHERE v.season_id = s.id),
        'active_versions',    (SELECT count(*) FROM model_versions v
                               WHERE v.season_id = s.id AND v.status = 'active'),
        'entered_versions',   (SELECT count(*) FROM model_versions v
                               WHERE v.season_id = s.id),
        'matches_played',     s.matches_played,
        -- THE ROUND IT IS IN, and the reset waiting to start: what the leaderboard's header says
        -- ("Round 3 · 100 games each", "resets in 2 days", "Finals"). Null when it has none.
        'round',      (SELECT json_build_object('n', r.n, 'kind', r.kind, 'games', r.games,
                                                'started_at', r.applied_at)
                         FROM season_round(s.id) r WHERE r.n IS NOT NULL),
        'next_round', (SELECT json_build_object('n', w.n, 'kind', w.kind, 'games', w.games,
                                                'starts_at', w.starts_at)
                         FROM season_rounds w
                        WHERE w.season_id = s.id AND w.applied_at IS NULL AND w.cancelled_at IS NULL),
        -- No `playing` here: it moves at every claim, finish and release, so it has its own
        -- uncached route (soma-pub-playing) and never invalidates the season document.
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

-- WHETHER ANYONE MAY SEE A VERSION: `active`, `disabled` (a baseline switched off) or `superseded`.
-- One still being admitted, waiting for its trial or rejected is its owner's, read through
-- /v1/me/versions/{id}. Every public version route and match_public() ask this.
CREATE FUNCTION version_public(p_status model_status) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_status IN ('active', 'disabled', 'superseded');
$$;

-- WHETHER ANYONE MAY SEE A MATCH IN A LISTING: `matches.listed`, which finish sets for a match with
-- no trial and a trial's `pass` sets as its candidate goes public. A trial in progress, and a
-- rejected candidate's, stay the owner's, read through /v1/me/matches. The listing, the event
-- counter and a pick ask this. GET /v1/matches/{id} asks it of a trial only: a cancelled or failed
-- ordinary match is readable there by id. One column and no subquery, so the planner inlines it
-- and a query that asks it can use the partial indexes built on `listed`.
CREATE FUNCTION match_public(m matches) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT m.listed AND EXISTS (SELECT 1 FROM seasons s
                                 WHERE s.id = m.season_id AND s.visibility = 'public');
$$;

-- WHETHER A USER OWNS A VERSION SEATED IN A MATCH: what lets them read a private match.
CREATE FUNCTION match_seated(p_match uuid, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM match_seats ms
                     JOIN model_versions v ON v.id = ms.version_id
                     JOIN models e         ON e.id = v.model_id
                    WHERE ms.match_id = p_match AND e.owner_id = p_user);
$$;

-- A POINTER TO A MATCH, for a card that shows one it does not list: a profile model's latest, a
-- podium place's, a board's. `frame` says whether a last frame exists, so a card knows whether to
-- ask for it. NULL for no match.
CREATE FUNCTION match_ref_json(p_match uuid) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object('id', m.id, 'played_at', m.played_at,
                             'frame', EXISTS (SELECT 1 FROM match_frames f WHERE f.match_id = m.id))
      FROM matches m WHERE m.id = p_match;
$$;

-- THE HEADER OF AN UPLOADED MAP, or NULL when the file has none worth reading (N28): an `id` that
-- is a slug and whole-number `players`, `rows` and `cols`. It is what the platform reads out of a
-- board and ALL it reads -- the rest of the file is the cartridge's, judged by its own worldgen.
-- Each cast sits behind the pattern that makes it safe, so a file saying "players": "two" is a NULL
-- header and a 400, never a 22P02 on the upload path.
--
-- `hills` is the LENGTH of the file's `hills` array -- players x H entries -- or null when the file
-- has none. A count and no placement: where the hills are is the cartridge's.
CREATE FUNCTION season_map_header(v jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(v) = 'object'
         AND jsonb_typeof(v -> 'id') = 'string'
         AND (v ->> 'id') ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(v ->> 'id') <= 64
         AND jsonb_typeof(v -> 'players') = 'number' AND (v ->> 'players') ~ '^[0-9]{1,3}$'
         AND jsonb_typeof(v -> 'rows') = 'number' AND (v ->> 'rows') ~ '^[0-9]{1,3}$'
         AND jsonb_typeof(v -> 'cols') = 'number' AND (v ->> 'cols') ~ '^[0-9]{1,3}$'
        THEN jsonb_build_object('id', v ->> 'id', 'players', (v ->> 'players')::int,
                                'rows', (v ->> 'rows')::int, 'cols', (v ->> 'cols')::int,
                                'hills', CASE WHEN jsonb_typeof(v -> 'hills') = 'array'
                                              THEN jsonb_array_length(v -> 'hills') END)
    END;
$$;

-- WHAT A BOARD'S NAME SAYS: `size-terrain-Np-Hh` split into its four parts, or NULL for a name off
-- the pattern. The words are stored as given; Soma keeps no list of sizes or terrains, so a second
-- game with other words needs no schema change. The upload refuses a NULL, and a name whose `Np`
-- or `Hh` disagrees with the file.
CREATE FUNCTION season_map_name(p_map_id text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_map_id ~ '^[a-z]+-[a-z]+-[0-9]{1,3}p-[0-9]{1,3}h$'
                THEN jsonb_build_object(
                    'size',    split_part(p_map_id, '-', 1),
                    'terrain', split_part(p_map_id, '-', 2),
                    'players', rtrim(split_part(p_map_id, '-', 3), 'p')::int,
                    'hills',   rtrim(split_part(p_map_id, '-', 4), 'h')::int) END;
$$;

-- WHY AN UPLOADED BOARD'S NAME IS REFUSED, or NULL when it is not: off the pattern, a seat count
-- that is not the file's `players`, or hills that are not the file's `hills` array divided by its
-- players. Asked by the upload's context read, which answers the 422, and by its insert, which
-- stores nothing the read would refuse.
CREATE FUNCTION season_map_name_problem(h jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN n IS NULL THEN 'map_name_pattern'
        WHEN (n ->> 'players')::int <> (h ->> 'players')::int THEN 'map_name_players'
        WHEN (h ->> 'hills') IS NULL
          OR (h ->> 'hills')::int <> (n ->> 'hills')::int * (h ->> 'players')::int
            THEN 'map_name_hills'
    END
      FROM (SELECT season_map_name(h ->> 'id') AS n) x;
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
--
-- `latest_match` is what the maps page's Watch opens: the board's newest counted match. Both it
-- and `matches` are columns the fold moves, so the page costs a row per board.
CREATE FUNCTION season_map_json(sm season_maps) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'map_id',   sm.map_id,
        'players',  sm.players,
        'rows',     sm.rows,
        'cols',     sm.cols,
        'size',     sm.size,
        'terrain',  sm.terrain,
        'hills',    sm.hills,
        'enabled',  sm.enabled,
        'added_at', sm.added_at,
        'matches',  sm.matches,
        'latest_match', match_ref_json(sm.latest_match_id));
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

-- WHO MAY ENTER (N30, §I). `entry = 'open'` admits anyone who may see the season; `restricted`
-- admits a PARTICIPANT. A season's `providers` allow-list (NULL = any provider) narrows BOTH: the
-- caller must hold an identity from a permitted provider, so a university season that lists its own
-- directory shuts a GitHub identity out even where a login is listed. A participant is a
-- season_participants row pinned to this user, a wildcard row (null login) of a provider the user
-- has an identity with, or an unpinned row whose (provider, login) matches one of the user's
-- identities -- resolved against `identities` at the time of asking, not at add, because a cohort is
-- written before most of its members have signed in, so a member listed by login is admitted at
-- their first sign-in without an edit. A pinned row still requires a permitted identity, so it too
-- honours `providers`. A baseline (no identity) is never admitted, which is right: it does not enter.
-- A SEASON ADMIN OF THIS SEASON never enters it (BRD Q2, S5): they run its roster and its boards,
-- so a standing of theirs in it would be judged by themselves. season_is_admin() says so, and the
-- submission's `why` reads it to refuse by name.
CREATE FUNCTION season_is_admin(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM season_admins sa
                    WHERE sa.season_id = s.id AND sa.user_id = p_user AND sa.removed_at IS NULL);
$$;

CREATE FUNCTION season_admits(s seasons, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT season_is_admin(s, p_user) AND EXISTS (
        SELECT 1 FROM identities i
         WHERE i.user_id = p_user
           AND (s.providers IS NULL
                OR i.provider IN (SELECT jsonb_array_elements_text(s.providers)))
           AND (s.entry = 'open'
                OR EXISTS (SELECT 1 FROM season_participants sp
                            WHERE sp.season_id = s.id AND sp.removed_at IS NULL
                              AND (sp.user_id = p_user
                                OR (sp.provider = i.provider AND sp.login IS NULL)
                                -- A login matches only while no account holds the row: once
                                -- pinned (at add, or at sign-in), the row is its account's alone.
                                OR (sp.user_id IS NULL AND sp.provider = i.provider
                                    AND lower(sp.login) = lower(i.login))))));
$$;

-- WHO MAY SEE A SEASON (N30). `public` is everyone's. `private` is its participants' (season_admits),
-- its season admins' and platform admins' alone -- to anyone else every route naming it must answer
-- as for a season that does not exist (Phase 4 wires this into every public read; defined here beside
-- season_admits, which it reuses). A NULL viewer is the anonymous public: they see public seasons only.
CREATE FUNCTION season_visible(s seasons, p_viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT s.visibility = 'public'
        OR (p_viewer IS NOT NULL AND (
               season_admits(s, p_viewer)
            OR EXISTS (SELECT 1 FROM season_admins sa
                        WHERE sa.season_id = s.id AND sa.user_id = p_viewer AND sa.removed_at IS NULL)
            OR EXISTS (SELECT 1 FROM users u
                        WHERE u.id = p_viewer AND u.role = 'admin')));
$$;

-- THE SEASON A READ IS ABOUT, FOR ONE VIEWER: public_season()'s resolution with the viewer's
-- visibility. A named slug resolves when season_visible() lets the viewer see it -- so a member, a
-- season admin or a platform admin reaches a private season by its slug, and anyone else gets
-- nothing, as for a season that does not exist. Without a slug it is the featured season exactly as
-- public_season() picks it: a private season is never anyone's default. A NULL viewer is the
-- anonymous public, and this is then public_season() itself -- which is how one statement serves
-- both a cached public route (no viewer) and a member's uncached one.
CREATE FUNCTION viewable_season(p_game uuid, p_slug text, p_viewer uuid)
RETURNS SETOF seasons LANGUAGE sql STABLE AS $$
    SELECT s.* FROM seasons s
     JOIN games g ON g.id = s.game_id
     WHERE s.game_id = p_game
       AND ((p_slug IS NULL AND s.visibility = 'public')
         OR (p_slug IS NOT NULL AND s.slug = p_slug AND season_visible(s, p_viewer)))
     ORDER BY (g.featured_season_id = s.id) DESC,
              (s.closed_at IS NULL) DESC,
              s.number DESC
     LIMIT 1;
$$;

-- WHETHER ONE VIEWER MAY SEE A MATCH IN A LISTING: match_public() with the viewer's visibility --
-- `listed`, and a season the viewer may see. A NULL viewer is match_public().
CREATE FUNCTION match_visible(m matches, p_viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT m.listed AND EXISTS (SELECT 1 FROM seasons s
                                 WHERE s.id = m.season_id AND season_visible(s, p_viewer));
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

-- entries.max_per_user -- asked by the SUBMISSION, not the entry create (N30/C1). An entry (a
-- `models` row) is per owner and game and free to make; the CAP is per SEASON, because a competitor
-- may field different entries in a public season and a cohort's. It counts the DISTINCT entries the
-- user already has a version of in THIS season, and exempts the entry being submitted to (p_model):
-- a further submission to an entry already in the season adds a version, not an entry, and is never
-- capped -- only a FIRST submission that would bring a new entry into the season is refused, and
-- only when the user is already at the cap. p_model left NULL asks "is there room for one more
-- entry", which is the preflight's may_add_model. A retired entry frees its slot.
CREATE FUNCTION season_admits_entry(s seasons, p_user uuid, p_model uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT coalesce((s.rules -> 'entries' ->> 'enabled')::bool, false)
        OR (s.rules -> 'entries' -> 'max_per_user') IS NULL
        OR EXISTS (SELECT 1 FROM model_versions v
                    WHERE v.model_id = p_model AND v.season_id = s.id)
        OR (SELECT count(DISTINCT v.model_id) FROM model_versions v
             JOIN models e ON e.id = v.model_id
            WHERE e.owner_id = p_user AND v.season_id = s.id AND e.retired_at IS NULL)
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
-- standings.ranked_per_user_max is read HERE and nowhere else -- ladder_field() and ladder_at()
-- both cap by it. It is work the entry split makes necessary: one active version per entry per
-- season means a competitor with five entries holds five rows, and without a cap the top ten is
-- one name. No cap is int's maximum, so a caller compares without a coalesce.
CREATE FUNCTION season_owner_cap(p_season uuid) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT CASE WHEN coalesce((s.rules -> 'standings' ->> 'enabled')::bool, false)
                                 THEN (s.rules -> 'standings' ->> 'ranked_per_user_max')::int END
                       FROM seasons s WHERE s.id = p_season), 2147483647);
$$;

CREATE FUNCTION ladder_field(p_season uuid, p_ladder ladder)
RETURNS TABLE (version_id uuid, owner_id uuid, conservative float8)
LANGUAGE sql STABLE AS $$
    WITH eligible AS (
        SELECT v.id, e.owner_id, r.conservative,
               row_number() OVER (PARTITION BY e.owner_id
                                  ORDER BY r.conservative DESC, v.id) AS per_owner
          FROM model_versions v
          JOIN models e   ON e.id = v.model_id
          -- One rated ladder: every field, a weight class among them, ranks by the OPEN rating.
          -- A class ladder is Open filtered to that class, so the two can never disagree about order.
          JOIN ratings r  ON r.version_id = v.id AND r.ladder = 'open'
         WHERE v.season_id = p_season AND v.status = 'active'
           AND (p_ladder = 'open' OR v.weight_class = p_ladder))
    SELECT eligible.id, eligible.owner_id, eligible.conservative
      FROM eligible
     WHERE eligible.per_owner <= season_owner_cap(p_season);
$$;

-- Which of the two clocks a version is waiting on, in the words the pages print. Four routes say
-- this; a version whose row is 'testing' or 'verified' yields the first three states only.
-- 'verifying' is somebody working on it: the admit clock, a runner holding its admission, or a
-- report the clock has yet to judge. Waiting for a runner to pick it up is still 'queued'.
CREATE FUNCTION model_phase(v model_versions) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN v.status = 'testing' AND v.admit_started_at IS NULL
                 AND NOT EXISTS (SELECT 1 FROM admissions a
                                  WHERE a.version_id = v.id
                                    AND (a.report IS NOT NULL OR a.lease_expires_at > now()))
                                     THEN 'queued'
                WHEN v.status = 'testing'   THEN 'verifying'
                WHEN v.status = 'verified'  THEN 'awaiting_trial'
                WHEN v.status = 'active'    THEN 'on_the_ladder'
                WHEN v.status = 'disabled'  THEN 'disabled'
                WHEN v.status = 'rejected'  THEN 'rejected'
                ELSE                             'superseded' END;
$$;

-- A number out of a runner's report as a whole, non-negative bigint, or NULL -- never a cast error.
-- A nested CASE, because the outer test must run first: `'x'::numeric` raises.
CREATE FUNCTION admission_num(j jsonb) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(j) = 'number'
                THEN CASE WHEN (j #>> '{}')::numeric >= 0 AND (j #>> '{}')::numeric < 1e18
                          THEN floor((j #>> '{}')::numeric)::bigint END END;
$$;

-- WHAT A RUNNER FOUND, AS FACTS THE ADMIT CLOCK CAN JUDGE. The report is JSON a runner built, and the
-- clock binds parts of it into statements -- where a float in an integer column or a string where a
-- number was is not one refused submission but a failed statement in the batch, which stops
-- admission for everyone behind it. So every value is typed here, and a malformed one is a missing
-- fact, which the clock treats as ours: the report goes back to the queue and keeps its attempt.
--
-- WHOSE FAULT A REFUSAL IS, on Orion's stage (model/admission.rs and artifact.rs). `size`, `digest`,
-- `parse` and `probe` are the artifact's, and `refused` names them as a competitor reads them.
-- `gate`, `head`, `fetch` and `cache` are the runner reaching the bucket, and so is an admission
-- that ran out of time. A probe over `models.max_probe_ms` is the runner's too: wall clock belongs to
-- the machine that measured it, and one busy with anything else is slower than the model. Those go
-- back to the queue as `again`, so one machine's load costs an attempt and not the verdict; a model
-- whose probe is slow on every attempt expires PROBE_TOO_SLOW (admissions.slow_probes).
--
-- `size` is S': the larger of the bucket's answer to the clock's own HEAD and the bytes the runner
-- fetched and re-hashed, plus the manifest -- so no report can make a model smaller than it is.
-- A probe that evaluated nothing, or that a runner says errored, is no probe at all.
--
-- THE MEMORY ROUND TRIP. A runner feeds a model that declares `memory` or `ant_memory` its own last
-- output on each reference observation that follows one of the same size, and reports
-- `probe.round_trip` as {checked: calls fed a memory, failed: of those, calls that failed}; absent
-- for a model with no memory. A memory input that cannot take the model's own output would strike
-- every turn after the first, so any failure is `round_trip_refused`, MEMORY_ROUND_TRIP, final and
-- the competitor's.
CREATE FUNCTION admission_facts(a admissions) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN a.report IS NULL THEN NULL ELSE (
      SELECT json_build_object(
        'admitted', r.state = 'passed',
        'refused',  CASE WHEN r.state = 'failed' AND r.theirs THEN upper(r.stage) || '_FAILED' END,
        'again',    CASE WHEN r.state = 'passed'  THEN NULL
                         WHEN r.state <> 'failed' THEN 'ADMISSION_UNREACHABLE'
                         WHEN r.slow              THEN 'PROBE_TOO_SLOW'
                         WHEN r.late              THEN 'ADMISSION_TIMED_OUT'
                         WHEN NOT r.theirs        THEN 'ARTIFACT_UNREACHABLE' END,
        'parameters', admission_num(a.report #> '{stats,parameters}'),
        'opset',      admission_num(a.report #> '{stats,opset}'),
        'operators',  CASE WHEN jsonb_typeof(a.report #> '{stats,operators}') = 'array'
                           THEN a.report #> '{stats,operators}' ELSE '[]'::jsonb END,
        'probe_dims', CASE WHEN jsonb_typeof(a.report #> '{stats,probe_dims}') = 'object'
                           THEN a.report #> '{stats,probe_dims}' ELSE '{}'::jsonb END,
        'size',       greatest(a.artifact_bytes,
                               coalesce(admission_num(a.report #> '{stats,artifact_bytes}'), 0))
                      + length(a.manifest),
        'probe',      CASE WHEN jsonb_typeof(a.report -> 'probe') = 'object'
                            AND a.report #> '{probe,errored}' IS DISTINCT FROM 'true'::jsonb
                            AND admission_num(a.report #> '{probe,checked}') > 0
                           THEN json_build_object(
                                'ok',           coalesce(a.report #> '{probe,ok}' = 'true'::jsonb, false),
                                'over_budget',  coalesce(a.report #> '{probe,over_budget}' = 'true'::jsonb,
                                                         false),
                                'reason',       CASE WHEN a.report #>> '{probe,reason}'
                                                          IN ('ADAPTER_INVALID', 'HEAD_UNREADABLE')
                                                     THEN a.report #>> '{probe,reason}' END,
                                'ops_max',      admission_num(a.report #> '{probe,ops_max}'),
                                'infer_us_max', admission_num(a.report #> '{probe,infer_us_max}'),
                                'checked',      admission_num(a.report #> '{probe,checked}'),
                                'round_trip',   CASE WHEN jsonb_typeof(a.report #> '{probe,round_trip}') = 'object'
                                                     THEN json_build_object(
                                                          'checked', admission_num(a.report #> '{probe,round_trip,checked}'),
                                                          'failed',  admission_num(a.report #> '{probe,round_trip,failed}'))
                                                END) END,
        'round_trip_refused', CASE WHEN admission_num(a.report #> '{probe,round_trip,failed}') > 0
                                   THEN 'MEMORY_ROUND_TRIP' END)
        FROM (SELECT s.state, s.stage, s.why,
                     s.stage IN ('size', 'digest', 'parse', 'probe')
                         AND position('models.max_probe_ms' IN s.why) = 0
                         AND position('admission_timeout_secs' IN s.why) = 0 AS theirs,
                     s.stage = 'probe' AND position('models.max_probe_ms' IN s.why) > 0 AS slow,
                     position('admission_timeout_secs' IN s.why) > 0 AS late
                FROM (SELECT coalesce(a.report #>> '{admission,state}', '') AS state,
                             coalesce(a.report #>> '{admission,stage}', '') AS stage,
                             coalesce(a.report #>> '{admission,reason}', '') AS why) s) r)
    END;
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
        'memory_bytes',  v.memory_bytes,
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
    -- ONE RATING, RANKED TWO WAYS. A version has a single rated row, on Open. Its class standing is
    -- its place on the Open ladder among same-size versions: the SAME mu/sigma/conservative with a
    -- class-filtered rank -- so the two keys can never disagree about which of two same-size models
    -- is ahead. The keys are 'open' and the version's own weight_class (never equal: weight_class is
    -- never 'open'), each ranked through ladder_field(), the one definition of a field.
    SELECT coalesce(json_object_agg(x.ladder, json_build_object(
        'rating',      r.conservative,
        'mu',          r.mu,
        'sigma',       r.sigma,
        'provisional', r.sigma > p_settled_sigma,
        'matches',     r.matches_played,
        'rank',  (SELECT count(*) + 1 FROM ladder_field(v.season_id, x.ladder) f
                  WHERE f.conservative > r.conservative
                     OR (f.conservative = r.conservative AND f.version_id < v.id)),
        -- The version itself counts, whether or not it is ON the ladder. Without the second term a
        -- superseded version reads "rank 6 of 5": it is ranked against the live field but was not
        -- one of it. Dropped into the five playing now, it would be sixth of six. The test is
        -- membership and not `status = 'active'`, because standings.ranked_per_user_max can leave
        -- an active version off the ladder its own page still ranks it against.
        'field', (SELECT count(*) FROM ladder_field(v.season_id, x.ladder) f)
                 + (CASE WHEN EXISTS (SELECT 1 FROM ladder_field(v.season_id, x.ladder) f2
                                       WHERE f2.version_id = v.id) THEN 0 ELSE 1 END)
    )), '{}'::json)
    FROM ratings r
    JOIN model_versions v ON v.id = r.version_id
    CROSS JOIN LATERAL (VALUES ('open'::ladder), (v.weight_class)) AS x (ladder)
    WHERE r.version_id = p_version AND r.ladder = 'open' AND x.ladder IS NOT NULL;
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

-- ------------------------------------------------------------- the redesign's shapes

-- A MATCH AS A CARD: the public listing's row, which the owner's listing, the related rail, the
-- picks and the match page return too. `margin` and `upset` are the stored sort keys, `comments`
-- the thread's live count, and `frame` whether a last frame exists, so a card asks for one only
-- when there is one. It takes the ROW, which every caller already holds, so a page of cards is not
-- a page of primary-key reads. `p_viewer` adds `mine` to each seat, for the owner's listing.
CREATE FUNCTION match_summary_json(m matches, p_viewer uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id',         m.id,
        'game',       (SELECT g.slug FROM games g WHERE g.id = m.game_id),
        'season',     (SELECT se.slug FROM seasons se WHERE se.id = m.season_id),
        'status',     m.status,
        'map',        (SELECT sm.map_id FROM season_maps sm WHERE sm.id = m.season_map_id),
        'seed',       m.seed,
        'reason',     m.reason,
        'turns',      m.turns,
        'played_at',  m.played_at,
        'ladders',    array_to_json(m.ladders),
        'is_trial',   m.trial_version_id IS NOT NULL,
        'margin',     m.margin,
        'upset',      m.upset,
        'comments',   coalesce((SELECT t.comments FROM threads t WHERE t.match_id = m.id), 0),
        'frame',      EXISTS (SELECT 1 FROM match_frames f WHERE f.match_id = m.id),
        'seats', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'seat', s.seat, 'version_id', s.version_id, 'model_id', s.model_id,
                     'model', s.model_name, 'owner', s.owner, 'baseline', s.baseline,
                     'class', s.class, 'version', s.version, 'rank', s.rank, 'score', s.score,
                     'strikes', s.strikes, 'outcome', s.outcome)
                     || CASE WHEN p_viewer IS NULL THEN '{}'::jsonb
                             ELSE jsonb_build_object('mine', s.owner_id = p_viewer) END
                     ORDER BY s.seat), '[]'::jsonb)
                    FROM match_seat_rows(m.id) s));
$$;

-- ONE MATCH, WHOLE: the match page's shape, which the public route and the owner's route both
-- return -- the card (match_summary_json) with each seat's rating_change, and what only the page
-- prints. Who may read it is each route's question: the public one asks match_public() of a
-- trial, and /v1/me/matches/{id} asks match_seated(), in any status -- which is how the owner of a
-- rejected candidate watches the trial it forfeited. The replay URL is signed by the route.
CREATE FUNCTION match_detail_json(mt matches) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT (c - 'comments') || jsonb_build_object(
        'played_ms',        mt.played_ms,
        'created_at',       mt.created_at,
        'withdrawn_reason', mt.withdrawn_reason,
        'successor_id',     mt.successor_version_id,
        'fault_reason',     mt.fault_reason,
        'engine_digest',    mt.engine_digest_played,
        'orion_version',    mt.orion_version,
        'strike_limit',     mt.strike_ceiling,
        'successor', (SELECT jsonb_build_object('version_id', sv.id, 'model_id', e.id, 'model', e.name,
                                                'owner', u.handle, 'version', sv.version)
                        FROM model_versions sv
                        JOIN models e ON e.id = sv.model_id
                        JOIN users u  ON u.id = e.owner_id
                       WHERE sv.id = mt.successor_version_id),
        'seats', (SELECT coalesce(jsonb_agg(x || jsonb_build_object(
                     'rating_change', (SELECT jsonb_object_agg(r.ladder, jsonb_build_object(
                                           'mu_before', r.mu_before, 'sigma_before', r.sigma_before,
                                           'mu_after', r.mu_after, 'sigma_after', r.sigma_after))
                                         FROM rating_events r
                                        WHERE r.match_id = mt.id AND r.seat = (x ->> 'seat')::smallint))
                     ORDER BY (x ->> 'seat')::int), '[]'::jsonb)
                    FROM jsonb_array_elements(c -> 'seats') x))
      FROM (SELECT match_summary_json(mt) AS c) card;
$$;

-- A MATCH'S TWO SORT KEYS, from one read of its seats. NULL both for a shared first place or a
-- match without a result.
--
-- `margin`: the winner's score minus the runner-up's. The runner-up is the best rank below first,
-- which is a forfeit's too when it is the only one left: a DQ is still a score the winner beat.
--
-- `upset`, on the Open ladder: the best conservative rating BEFORE THE MATCH among the seats the
-- winner beat, disqualified seats left out, minus the winner's own. Positive is an upset; NULL when
-- nobody was beaten fairly. "Before the match" is read two ways and they agree. The fold computes
-- it in the statement that rates the match, where this match's rating_events do not exist yet and
-- `ratings` is still the snapshot before the fold's own update -- so the coalesce falls through to
-- `ratings`. The cutover's backfill runs long after, where `ratings` has moved on and the event's
-- `*_before` is the number the fold would have read. A trial's verdict takes `margin` alone.
CREATE FUNCTION match_sort_keys(p_match uuid) RETURNS TABLE (margin int, upset float8)
LANGUAGE sql STABLE AS $$
    WITH seat AS (
        SELECT s.rank, s.score, s.strikes >= m.strike_ceiling AS dq,
               coalesce((SELECT e.mu_before - 3 * e.sigma_before FROM rating_events e
                          WHERE e.match_id = s.match_id AND e.seat = s.seat AND e.ladder = 'open'),
                        (SELECT r.conservative FROM ratings r
                          WHERE r.version_id = s.version_id AND r.ladder = 'open')) AS rating
          FROM match_seats s JOIN matches m ON m.id = s.match_id
         WHERE s.match_id = p_match AND s.rank IS NOT NULL),
    second AS (SELECT min(seat.rank) AS rank FROM seat WHERE seat.rank > 1)
    SELECT CASE WHEN count(*) FILTER (WHERE seat.rank = 1) = 1
                THEN max(seat.score) FILTER (WHERE seat.rank = 1)
                     - max(seat.score) FILTER (WHERE seat.rank = second.rank) END,
           CASE WHEN count(*) FILTER (WHERE seat.rank = 1) = 1
                THEN max(seat.rating) FILTER (WHERE seat.rank > 1 AND NOT seat.dq)
                     - max(seat.rating) FILTER (WHERE seat.rank = 1) END
      FROM seat, second;
$$;

-- ONE VERSION, as every route that shows one returns it: the version page, a model's list, the
-- owner's own. WHO MAY SEE IT is the route's question, not this function's -- the public routes ask
-- for `active`, `disabled` and `superseded` and answer 404 otherwise, and /v1/me/versions/{id}
-- returns the rest to the owner. The id is `version_id`, as every seat, list and ladder names it.
CREATE FUNCTION version_json(v model_versions, p_settled_sigma float8) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'version_id',    v.id,
        'model_id',      e.id,
        'model',         e.name,
        'owner',         u.handle,
        'baseline',      u.role = 'baseline',
        'game',          g.slug,
        'season',        se.slug,
        'version',       v.version,
        'note',          v.note,
        'class',         v.weight_class,
        'class_max_bytes', (wc.x ->> 'max_bytes')::bigint,
        'class_memory_flat_bytes', (wc.x ->> 'memory_flat_bytes')::bigint,
        'class_memory_cell_bytes', (wc.x ->> 'memory_cell_bytes')::bigint,
        'size_bytes',    v.size_bytes,
        'memory_bytes',  v.memory_bytes,
        'param_count',   v.param_count,
        'infer_us',      v.infer_us,
        'weights_hash',  v.weights_hash,
        'manifest_hash', v.manifest_hash,
        'orion_version', v.orion_version,
        'status',        v.status,
        'phase',         model_phase(v),
        'admit_attempt', CASE WHEN v.status = 'testing'
                              THEN (SELECT a.attempts FROM admissions a WHERE a.version_id = v.id) END,
        'successor',     (SELECT s.version FROM model_versions s
                           WHERE s.model_id = v.model_id AND s.season_id = v.season_id
                             AND s.status = 'active' AND v.status = 'superseded'),
        'reject_reason', v.reject_reason,
        'created_at',    v.created_at,
        'trial',         (SELECT json_build_object(
                              'match_id', t.id, 'status', t.status, 'map', tm.map_id,
                              'queued_at', t.created_at,
                              'waiting_s', CASE WHEN t.status = 'pending'
                                                THEN round(extract(epoch FROM now() - t.created_at))::bigint END)
                            FROM matches t JOIN season_maps tm ON tm.id = t.season_map_id
                           WHERE t.trial_version_id = v.id
                           ORDER BY t.created_at DESC LIMIT 1),
        'ratings',       model_ratings(v.id, p_settled_sigma),
        'last_played_at', (SELECT max(mt.played_at) FROM match_seats ms
                             JOIN matches mt ON mt.id = ms.match_id
                            WHERE ms.version_id = v.id))
      FROM models e
      JOIN users u    ON u.id = e.owner_id
      JOIN games g    ON g.id = e.game_id
      JOIN seasons se ON se.id = v.season_id
      -- the version's class as its own season states it, memory numbers filled in
      LEFT JOIN LATERAL (SELECT x FROM jsonb_array_elements(weight_classes_public(se.weight_classes)) AS x
                          WHERE x ->> 'class' = v.weight_class::text) wc ON true
     WHERE e.id = v.model_id;
$$;

-- A MATCH THAT COUNTS: public and not a trial -- what every season listing, sort and count reads,
-- and the predicate each partial index on `matches` is built on. Row-local, so it inlines.
CREATE FUNCTION match_counted(m matches) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT m.listed AND m.trial_version_id IS NULL;
$$;

-- A THREAD'S HOST, as every route names it: `match` or `model`, its id, and the link to a comment
-- on it. Notifications carry the link, so a page and the bell cannot disagree about where it is.
CREATE FUNCTION thread_host(t threads) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN t.match_id IS NOT NULL THEN 'match' ELSE 'model' END;
$$;
CREATE FUNCTION thread_host_id(t threads) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(t.match_id, t.model_id);
$$;
CREATE FUNCTION comment_link(t threads, p_comment uuid) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN t.match_id IS NOT NULL THEN '/matches/' ELSE '/models/' END
           || coalesce(t.match_id, t.model_id) || '#comment-' || p_comment;
$$;

-- WHO OWNS A THREAD'S HOST: the model's owner, or each owner of a version seated in the match.
-- The Owner tag on a comment and the `comment` notification both ask this.
CREATE FUNCTION thread_owners(t threads) RETURNS SETOF uuid LANGUAGE sql STABLE AS $$
    SELECT e.owner_id FROM models e WHERE e.id = t.model_id
    UNION
    SELECT e.owner_id FROM match_seats ms
      JOIN model_versions v ON v.id = ms.version_id
      JOIN models e         ON e.id = v.model_id
     WHERE ms.match_id = t.match_id;
$$;

-- WHETHER A HOST MAY CARRY A THREAD, FOR ONE VIEWER: exactly one of a match the viewer may see and a
-- model. A private season's match is a host among the people who see its season (BRD Q8), so its
-- thread is read through /v1/private/threads and posted to by them; a NULL viewer is the public.
CREATE FUNCTION thread_host_ok(p_match uuid, p_model uuid, p_viewer uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_match IS NOT NULL AND p_model IS NULL
                THEN EXISTS (SELECT 1 FROM matches m WHERE m.id = p_match AND match_visible(m, p_viewer))
                WHEN p_model IS NOT NULL AND p_match IS NULL
                THEN EXISTS (SELECT 1 FROM models e WHERE e.id = p_model)
                ELSE false END;
$$;

-- COMMENTING SWITCHED OFF RIGHT NOW: the end and the reason while it is, NULL once it has run out
-- or was never off. Every route that shows the switch or obeys it reads these.
CREATE FUNCTION commenting_off_until(u users) RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN u.comments_off_until > now() THEN u.comments_off_until END;
$$;
CREATE FUNCTION commenting_off_reason(u users) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN u.comments_off_until > now() THEN u.comments_off_reason END;
$$;
-- The end of a switch-off an admin asks for: a day, a week, a month, or for good. NULL for any
-- other word.
CREATE FUNCTION commenting_off_end(p_term text) RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT CASE p_term WHEN 'day'     THEN now() + interval '1 day'
                       WHEN 'week'    THEN now() + interval '7 days'
                       WHEN 'month'   THEN now() + interval '1 month'
                       WHEN 'forever' THEN 'infinity'::timestamptz END;
$$;

-- HOW LONG A USER MUST WAIT TO COMMENT: `wait_s` until 15 s after their last comment, and
-- `day_wait_s` until the oldest of their last hundred leaves the 24 hours. Every state counts, so
-- deleting and writing again resets neither. NULL for a limit not in force. The post writes only
-- when both are NULL, and `why` returns them.
CREATE FUNCTION comment_wait(p_user uuid) RETURNS TABLE (wait_s int, day_wait_s int)
LANGUAGE sql STABLE AS $$
    WITH recent AS (
        SELECT c.created_at FROM comments c
         WHERE c.author_id = p_user AND c.created_at > now() - interval '24 hours'
         ORDER BY c.created_at DESC LIMIT 100)
    SELECT (SELECT ceil(extract(epoch FROM max(r.created_at) + interval '15 seconds' - now()))::int
              FROM recent r WHERE r.created_at > now() - interval '15 seconds'),
           CASE WHEN (SELECT count(*) FROM recent) >= 100
                THEN (SELECT ceil(extract(epoch FROM min(r.created_at) + interval '24 hours' - now()))::int
                        FROM recent r) END;
$$;

-- A STORY'S HELD EDIT, as its writer and the admin desk see it; NULL while none waits.
CREATE FUNCTION story_pending_json(s model_stories) RETURNS json LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN s.hold_tag IS NOT NULL
                THEN json_build_object('title', s.pending_title, 'body', s.pending_body,
                                       'hold_tag', s.hold_tag) END;
$$;

-- AN ANNOUNCEMENT IN FORCE: not disabled and not past its end.
CREATE FUNCTION announcement_live(a announcements) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT a.disabled_at IS NULL AND (a.ends_at IS NULL OR a.ends_at > now());
$$;

-- A STORY THE PUBLIC READS: approved text, not removed.
CREATE FUNCTION story_public(s model_stories) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT s.removed_at IS NULL AND s.title IS NOT NULL AND s.body IS NOT NULL;
$$;

-- THE LIVE COUNT ON A THREAD, kept by the table rather than by each writer: a comment entering
-- `live` adds one, leaving it takes one away, whoever writes the state -- a post, a delete, an
-- admin's decision, a restore.
CREATE FUNCTION threads_count_live() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.state = 'live') IS DISTINCT FROM (TG_OP = 'UPDATE' AND OLD.state = 'live') THEN
        UPDATE threads SET comments = comments + CASE WHEN NEW.state = 'live' THEN 1 ELSE -1 END
         WHERE id = NEW.thread_id;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER comments_count_live AFTER INSERT OR UPDATE OF state ON comments
    FOR EACH ROW EXECUTE FUNCTION threads_count_live();

-- WHETHER A USER MAY WRITE A MODEL'S STORY OR ITS VERSIONS' NOTES: its owner, or an admin for a
-- baseline's model, whose words the team writes.
CREATE FUNCTION model_writable_by(p_model uuid, p_user uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM models e
                     JOIN users o ON o.id = e.owner_id
                     JOIN users u ON u.id = p_user
                    WHERE e.id = p_model
                      AND (e.owner_id = u.id OR (u.role = 'admin' AND o.role = 'baseline')));
$$;

-- A NOTIFY AUDIENCE, VALIDATED: chips that combine as a union. {"everyone": true}; {"game",
-- "season"}, a season's submitters, narrowed by "class" to one weight class; "models", each
-- model's owner; "handles", typed by hand. Every set function sits behind a CASE, because SQL does
-- not promise to evaluate the type tests first and jsonb_object_keys() on a scalar raises.
CREATE FUNCTION notify_audience_ok(a jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(jsonb_typeof(a) = 'object'
        AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(CASE WHEN jsonb_typeof(a) = 'object'
                                                             THEN a ELSE '{}'::jsonb END) k
                         WHERE k NOT IN ('everyone', 'game', 'season', 'class', 'models', 'handles'))
        AND (a -> 'everyone' = 'true'::jsonb OR a ? 'season' OR a ? 'models' OR a ? 'handles')
        AND (NOT a ? 'everyone' OR jsonb_typeof(a -> 'everyone') = 'boolean')
        AND (NOT a ? 'season'
             OR (jsonb_typeof(a -> 'season') = 'string' AND jsonb_typeof(a -> 'game') = 'string'))
        AND (NOT a ? 'game' OR a ? 'season')
        AND (NOT a ? 'class'
             OR (a ? 'season' AND (a ->> 'class') IN (SELECT l::text FROM unnest(enum_range(NULL::ladder)) l
                                                       WHERE l <> 'open')))
        AND (NOT a ? 'models'
             OR (jsonb_typeof(a -> 'models') = 'array'
                 AND jsonb_array_length(CASE WHEN jsonb_typeof(a -> 'models') = 'array'
                                             THEN a -> 'models' ELSE '[]'::jsonb END) BETWEEN 1 AND 100))
        AND (NOT a ? 'handles'
             OR (jsonb_typeof(a -> 'handles') = 'array'
                 AND jsonb_array_length(CASE WHEN jsonb_typeof(a -> 'handles') = 'array'
                                             THEN a -> 'handles' ELSE '[]'::jsonb END) BETWEEN 1 AND 500)),
        false);
$$;

-- A SEASON'S PEOPLE, whom its season admins may notify (S8): everyone who entered it, every
-- participant pinned to an account, and its season admins -- baselines never. An invite still
-- waiting for its account's first sign-in reaches nobody yet.
CREATE FUNCTION season_audience(p_season uuid) RETURNS TABLE (user_id uuid) LANGUAGE sql STABLE AS $$
    SELECT w.id
      FROM (SELECT e.owner_id AS id FROM model_versions v JOIN models e ON e.id = v.model_id
             WHERE v.season_id = p_season
            UNION
            SELECT sp.user_id FROM season_participants sp
             WHERE sp.season_id = p_season AND sp.removed_at IS NULL AND sp.user_id IS NOT NULL
            UNION
            SELECT sa.user_id FROM season_admins sa
             WHERE sa.season_id = p_season AND sa.removed_at IS NULL) w
      JOIN users u ON u.id = w.id AND u.role <> 'baseline';
$$;

-- WHO A NOTIFY AUDIENCE NAMES: a union of id sets, each read the cheap way, baselines dropped --
-- nobody signs in to one. Nobody for an audience notify_audience_ok() refuses. The count route
-- and the send ask this, so what a count promised is who a send writes to.
CREATE FUNCTION notify_audience(a jsonb) RETURNS TABLE (user_id uuid) LANGUAGE sql STABLE AS $$
    SELECT w.id
      FROM (SELECT u.id FROM users u
             WHERE a -> 'everyone' = 'true'::jsonb
            UNION
            SELECT e.owner_id FROM games g
              JOIN seasons s        ON s.game_id = g.id
              JOIN model_versions v ON v.season_id = s.id
              JOIN models e         ON e.id = v.model_id
             WHERE a ? 'season' AND g.slug = a ->> 'game' AND s.slug = a ->> 'season'
               AND (NOT a ? 'class' OR v.weight_class::text = a ->> 'class')
            UNION
            SELECT e.owner_id FROM models e
             WHERE e.id::text IN (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(a -> 'models') = 'array'
                                                                       THEN a -> 'models' ELSE '[]'::jsonb END))
            UNION
            SELECT u.id FROM users u
             WHERE lower(u.handle) IN (SELECT lower(h) FROM jsonb_array_elements_text(
                                          CASE WHEN jsonb_typeof(a -> 'handles') = 'array'
                                               THEN a -> 'handles' ELSE '[]'::jsonb END) h)) w
      JOIN users u ON u.id = w.id AND u.role <> 'baseline'
     WHERE notify_audience_ok(a);
$$;

-- ONE COMMENT, as the thread and the profile return it. A removed or deleted comment keeps its place
-- while it has replies, with no author and no body. `owner` is the Owner tag: on a model's thread
-- the author owns the model, on a match's the author owns a version seated in it.
CREATE FUNCTION comment_json(c comments) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object(
        'id',         c.id,
        'parent_id',  c.parent_id,
        'root_id',    c.root_id,
        'state',      c.state,
        'hold_tag',   CASE WHEN c.state = 'held' THEN c.hold_tag END,
        'body',       CASE WHEN c.state IN ('live', 'held') THEN c.body END,
        'author',     CASE WHEN c.state IN ('live', 'held') THEN u.handle END,
        'owner',      c.state IN ('live', 'held')
                      AND c.author_id IN (SELECT o FROM thread_owners(t) o),
        'created_at', c.created_at)
      FROM users u, threads t
     WHERE u.id = c.author_id AND t.id = c.thread_id;
$$;

-- THE FIELD ON ONE LADDER AT AN INSTANT, and each version's conservative rating then. No column
-- records when a version joined or left a ladder; `rating_events` seq 0 does both. A version stands
-- from its own seq-0 row on Open, and until a later version of the same entry has one; a baseline
-- stands while its latest enable or disable at t is an enable. Its rating is its last event at or
-- before t. The per-owner cap is season_owner_cap(), as ladder_field() applies it, so a series and today's
-- leaderboard agree at `now()` about who is on the ladder.
--
-- It writes each hour's ladder_snapshots row and a series' last point; rating_events_at_idx is its
-- index. Anything that reads the field at many instants reads the snapshots instead.
CREATE FUNCTION ladder_at(p_season uuid, p_ladder ladder, p_t timestamptz)
RETURNS TABLE (version_id uuid, model_id uuid, owner_id uuid, conservative float8, rank bigint)
LANGUAGE sql STABLE AS $$
    WITH seeded AS (
        SELECT v.id, v.model_id, v.version, v.weight_class, e.owner_id,
               u.role = 'baseline' AS baseline
          FROM model_versions v
          JOIN models e        ON e.id = v.model_id
          JOIN users u         ON u.id = e.owner_id
          JOIN rating_events z ON z.version_id = v.id AND z.ladder = 'open' AND z.seq = 0
         WHERE v.season_id = p_season AND z.created_at <= p_t),
    standing AS (
        SELECT s.* FROM seeded s
         WHERE (p_ladder = 'open' OR s.weight_class = p_ladder)
           AND NOT EXISTS (SELECT 1 FROM seeded n WHERE n.model_id = s.model_id AND n.version > s.version)
           AND (NOT s.baseline
                OR coalesce((SELECT b.action = 'enable' FROM baseline_events b
                              WHERE b.version_id = s.id AND b.action <> 'upload' AND b.at <= p_t
                              ORDER BY b.at DESC, b.id DESC LIMIT 1), false))),
    rated AS (
        -- The rating is the OPEN event, whatever field p_ladder names: a class standing is Open
        -- filtered by `standing` above, ranked by the same conservative number.
        SELECT st.id, st.model_id, st.owner_id,
               (SELECT ev.mu_after - 3 * ev.sigma_after FROM rating_events ev
                 WHERE ev.version_id = st.id AND ev.ladder = 'open' AND ev.created_at <= p_t
                 ORDER BY ev.created_at DESC, ev.seq DESC LIMIT 1) AS c
          FROM standing st),
    capped AS (
        SELECT r.*, row_number() OVER (PARTITION BY r.owner_id ORDER BY r.c DESC, r.id) AS per_owner
          FROM rated r WHERE r.c IS NOT NULL)
    SELECT c.id, c.model_id, c.owner_id, c.c, row_number() OVER (ORDER BY c.c DESC, c.id)
      FROM capped c
     WHERE c.per_owner <= season_owner_cap(p_season);
$$;

-- THE RATING SERIES, IN BUCKETS: every version that stood on the ladder at any of `p_points` evenly
-- spaced edges from `p_since` to now (or the close), with its rating and rank at each edge and null
-- where it did not stand, and its `model_id` so a page joins a model's versions into one line.
-- Every edge but the last reads the hour's snapshot at or before it (ladder_snapshots), so a series
-- costs its points times the field, whatever the season's length; the last edge is ladder_at() at
-- that instant, so a live ladder's line ends where the leaderboard stands now.
CREATE FUNCTION rating_series(p_season uuid, p_ladder ladder, p_since timestamptz, p_points int)
RETURNS json LANGUAGE sql STABLE AS $$
    WITH span AS (
        SELECT least(p_since, e.t) AS since, e.t AS until, greatest(least(p_points, 200), 2) AS n
          FROM (SELECT coalesce(s.closed_at, now()) AS t FROM seasons s WHERE s.id = p_season) e),
    edges AS (
        SELECT i, span.since + (span.until - span.since) * (i::float8 / (span.n - 1)) AS t,
               i = span.n - 1 AS last
          FROM span, generate_series(0, span.n - 1) AS i),
    at AS (
        -- Non-last edges read the hour's OPEN snapshot (the only one written); a class series
        -- filters it to same-size versions and re-ranks within them, so a class line is the Open
        -- line restricted to a class. The last edge is ladder_at(), which class-filters the same way.
        SELECT ed.i, u.version_id, u.c,
               row_number() OVER (PARTITION BY ed.i ORDER BY u.c DESC, u.version_id) AS rank
          FROM edges ed
         CROSS JOIN LATERAL (SELECT sn.version_ids, sn.ratings FROM ladder_snapshots sn
                              WHERE sn.season_id = p_season AND sn.ladder = 'open' AND sn.at <= ed.t
                              ORDER BY sn.at DESC LIMIT 1) sn
         CROSS JOIN LATERAL unnest(sn.version_ids, sn.ratings) AS u (version_id, c)
          JOIN model_versions v ON v.id = u.version_id
         WHERE NOT ed.last AND (p_ladder = 'open' OR v.weight_class = p_ladder)
        UNION ALL
        SELECT ed.i, l.version_id, l.conservative, l.rank
          FROM edges ed, ladder_at(p_season, p_ladder, ed.t) l
         WHERE ed.last),
    -- Every version against every edge in ONE grouped join, null where it did not stand.
    series AS (
        SELECT w.version_id,
               json_agg(round(a.c::numeric, 2) ORDER BY ed.i) AS ratings,
               json_agg(a.rank ORDER BY ed.i) AS ranks
          FROM (SELECT DISTINCT at.version_id FROM at) w
         CROSS JOIN edges ed
          LEFT JOIN at a ON a.i = ed.i AND a.version_id = w.version_id
         GROUP BY w.version_id)
    SELECT json_build_object(
        'edges', (SELECT json_agg(ed.t ORDER BY ed.i) FROM edges ed),
        'versions', coalesce((
            SELECT json_agg(json_build_object(
                'version_id', sr.version_id,
                'model_id',   v.model_id,
                'model',      e.name,
                'owner',      u.handle,
                'baseline',   u.role = 'baseline',
                'version',    v.version,
                'ratings',    sr.ratings,
                'ranks',      sr.ranks)
                ORDER BY e.name, v.version)
              FROM series sr
              JOIN model_versions v ON v.id = sr.version_id
              JOIN models e         ON e.id = v.model_id
              JOIN users u          ON u.id = e.owner_id), '[]'::json));
$$;

-- THE LADDER READ BY OWNER: each owner's best version stands for them, baselines left out, ranked.
-- The podium is its first three places, and the close's "you finished 4th of 31" reads the same
-- ranks, so the notification and the podium cannot disagree about who placed where.
CREATE FUNCTION owner_ranks(p_season uuid, p_ladder ladder)
RETURNS TABLE (place bigint, version_id uuid, owner_id uuid, rating float8, field bigint)
LANGUAGE sql STABLE AS $$
    SELECT row_number() OVER (ORDER BY b.conservative DESC, b.version_id),
           b.version_id, b.owner_id, b.conservative, count(*) OVER ()
      FROM (SELECT DISTINCT ON (f.owner_id) f.version_id, f.owner_id, f.conservative
              FROM ladder_field(p_season, p_ladder) f
              JOIN users u ON u.id = f.owner_id AND u.role <> 'baseline'
             ORDER BY f.owner_id, f.conservative DESC, f.version_id) b;
$$;

-- THE PODIUM of one ladder: first to third of owner_ranks(). The close writes season_podium from
-- this, and the cutover's backfill calls the same function for every season already closed.
CREATE FUNCTION podium_of(p_season uuid, p_ladder ladder)
RETURNS TABLE (place smallint, version_id uuid, owner_id uuid, rating float8)
LANGUAGE sql STABLE AS $$
    SELECT o.place::smallint, o.version_id, o.owner_id, o.rating
      FROM owner_ranks(p_season, p_ladder) o
     WHERE o.place <= 3;
$$;

-- ---------------------------------------------------------------- table storage

-- Every match row is updated at least four times after insert -- claim, start, renew (repeatedly),
-- finish, rate -- and the renews are the reason for the headroom: 30% free gives those updates
-- somewhere on the same page to go, which keeps them heap-only and off the indexes.
ALTER TABLE matches SET (fillfactor = 70);

-- ------------------------------------------------------------------ the roles

-- Confine each writer by grant rather than by convention. No password is set: the credential is
-- deployment configuration, which `bootstrap` sets from RUNNER_GATE_DB_PASSWORD, so the committed
-- migration ships no secret. Roles are cluster-global while this schema is per-database, which is
-- why the create is guarded.

-- ------------------------------------------------------------ the runner gate

-- THE ROLE THE MACHINE-FACING ROUTES RUN AS. The /v1/runner/* routes run inside Soma's package,
-- over `soma-db-gate`, which connects as this role. A runner never reaches the database: it holds
-- no credential, and every statement it triggers is one Soma ships in
-- soma/workflows/soma-gate-*.json, fenced on its claim token.
--
-- WHAT IT CAN DO: read the two tables a match is played from, the board, the roster columns and
-- the row's season terms; write the columns a match player reports; claim and report an
-- admission; and hold runner identity -- `played_by`, `live_runners`, and the `runners` upsert the
-- token exchange performs.
--
-- WHAT IT CANNOT DO, and this is the list that matters: rate a match, cancel one or pair one; read
-- or write `ratings`, `rating_events`, `users`, `clocks` or `models`; or write `seasons`, `games` or
-- `model_versions`, and so decide no admission. "A runner statement cannot write a rating" is a
-- fact of this grant rather than of review. Do not widen it to make a route work: a route that
-- needs a grant is on the wrong connector.
--
-- THE FIVE ADMIN ROUTES STAY ON `soma-db`. `runner_keys` creation and revocation are Soma's auth
-- surface, the same as sessions, and they are session-authed rather than runner-authed.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'runner_gate') THEN
        CREATE ROLE runner_gate LOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO runner_gate;
GRANT SELECT ON matches, match_seats TO runner_gate;
GRANT SELECT (id, map_id, board) ON season_maps TO runner_gate;
GRANT SELECT (id, status, manifest, artifact_key, weights_hash, created_at, season_id)
    ON model_versions TO runner_gate;
-- The claim reads the row's own season and game to build the execution contract (N18). SELECT
-- only, and on the two columns that carry it: a runner's terms are read here, never decided here.
GRANT SELECT (id, game_id, rules, engine_digest, closed_at, fleet) ON seasons TO runner_gate;
GRANT SELECT (id, slug, manifest) ON games TO runner_gate;
-- The match player's columns, plus `played_by`, which the claim writes, and `listed`, which finish
-- writes. The runner decides no part of `listed`: finish sets it to `trial_version_id IS NULL`,
-- read off the row inside the statement, so a runner can publish an ordinary match it finished
-- and no trial.
GRANT UPDATE (status, claim_token, lease_expires_at, lapses, refusals, first_refused_at,
              reason, turns, played_ms, engine_digest_played, orion_version,
              replay_key, played_at, fault_reason, closed_at, played_by, listed)
    ON matches TO runner_gate;
GRANT UPDATE (rank, score, strikes, infer_us_total, infer_us_max, infer_turns)
    ON match_seats TO runner_gate;
-- THE LAST FRAME, which finish inserts beside the result under the same claim. INSERT and nothing
-- else: a frame is written once, by the statement that finishes its match, and never read back or
-- rewritten by a runner. It is opaque display material and decides nothing, so a runner that could
-- write any frame it liked could change a card's picture and no result.
GRANT INSERT ON match_frames TO runner_gate;
-- Runner identity, which the gate needs: the key lookup the token
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

-- ADMISSION, which an admitting runner executes and never decides. The claim takes a prepared row
-- under a lease and answers the registration, the artifact's key and digest, and the first of the
-- game's reference observations; the report stores what the runner found. So the role reads the
-- queue and the game's reference set (public: they ship in every ants release), sees a version's
-- game and status to join them, and writes only the claim and the report. The verdict columns --
-- status, weight_class, size_bytes, everything the admit clock writes on model_versions -- stay out
-- of reach: a runner reports, the clock judges.
GRANT SELECT (id, game_id) ON model_versions TO runner_gate;
GRANT SELECT (reference_observations) ON games TO runner_gate;
GRANT SELECT ON admissions TO runner_gate;
GRANT UPDATE (runner_id, claim_token, lease_expires_at, attempts, report, reported_at)
    ON admissions TO runner_gate;

-- THERE IS NO CLOCK ROLE. Four clocks -- admit, pair, count, withdraw -- run as the owner over
-- `soma-db`, the connector the routes use, and reap runs as `runner_gate` over `soma-db-gate`,
-- because returning a lapsed lease writes only the match player's columns. What confines the four
-- is `soma-db`'s `operations.delete = false` and review: a clock statement that deletes, reads
-- `sessions` or rewrites an entry is a review failure, not a grant error.

COMMIT;
