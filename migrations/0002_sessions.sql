-- Soma -- what belongs to one account and to nobody else: server-side sessions, so signing out
-- means something, and the notifications the platform addresses to that account.
--
-- The `soma_session` token carries a `sid` claim naming a row here, and every authed statement
-- JOINs `live_sessions` on it, so marking a row revoked ends the token before its 30-day `exp`.
-- The check is a join rather than a guard task on purpose: a JSONLogic guard fails open if it is
-- ever wrong, and a halted task answers 400 where the shell needs 401. The rule is enforced by the
-- same engine that enforces one-active-version, and the workflow only shapes the 401.
--
-- NOTHING HERE IS GRANTED TO `kalam` OR `runner_gate`, and the absence is the grant: this file
-- carries no GRANT at all, so neither role can read who is signed in or what they were told. The
-- clocks that write notifications run as the owner over `soma-db`.
--
-- Applied by devops' `db-bootstrap` on an empty database, after 0001; the schema is pre-release and
-- rewritten in place, so an existing database is rebuilt rather than migrated.

BEGIN;

-- One row per sign-in. `sid` is minted by the callback workflow and is not derivable from the
-- token's other claims, which is the point: two sign-ins by the same user in the same second are
-- otherwise indistinguishable. ON DELETE CASCADE is the second half of revocation -- deleting a
-- user ends their sessions rather than leaving live tokens naming a row that is gone.
CREATE TABLE sessions (
    sid         uuid        PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    issued_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz,

    -- The browser's own words, recorded once and never parsed here: a session list is only
    -- actionable if a person can recognise the session they want to end, and turning the string
    -- into "Firefox on macOS" is presentation that goes stale on its own.
    user_agent  text,

    -- BUCKETED, NOT EXACT. Updated by GET /v1/me -- the one route the shell calls on every page --
    -- and only when already more than five minutes old, so the common request writes nothing.
    -- "Last used 3 days ago" does not need better, and a write on every authed read would turn the
    -- cheapest statement in the package into the most expensive.
    last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- `expires_at` duplicates the token's own `exp`, which Orion enforces at the channel. It is kept
-- because the two are minted by different code from different clocks, and a row that outlives its
-- token is a lie about what is signed in.
--
-- The predicate lives in a view so it is written once. Every authed statement joins this, never
-- the table.
CREATE VIEW live_sessions AS
    SELECT sid, user_id, issued_at, expires_at, user_agent, last_seen_at
    FROM sessions
    WHERE revoked_at IS NULL
      AND expires_at > now();

-- "Sign out everywhere", and the session list behind it.
CREATE INDEX sessions_user_live_idx
    ON sessions (user_id)
    WHERE revoked_at IS NULL;

-- Nothing prunes this table: rows are ~60 bytes and expire in 30 days, so it is left to grow
-- rather than given a scheduler. The housekeeping statement, when it is worth running, is:
--   DELETE FROM sessions WHERE expires_at < now() - interval '30 days';

-- ------------------------------------------------------------- notifications

-- WHAT A NOTIFICATION MAY BE ABOUT, and what each category does for someone who never opened the
-- settings page. One row per category: season_rule_spec()'s argument applied here -- a VALUES list
-- rather than a table, so the CHECKs below never depend on rows a restore has not loaded yet, and
-- so this list IS the documentation of what the settings routes may return.
--
--   locked      the app switch cannot be turned off. `submissions` is a competitor's own work and
--               `account` is who signed in as them; a setting that let either go silent would hide
--               a rejection or a stranger's sign-in.
--   admin_only  receivable only while the account's role is `admin`, read off `users` at the time
--               of asking, so a demotion ends it at once -- the rule the admin routes follow.
--   app, push   the defaults. Push is stored and never delivered here: Web Push is not built.
--   levels      the vocabulary of `level`, and NULL where a category has none. Only `matches` has
--               one, because it is the only category whose volume is the ladder's rather than the
--               competitor's: `notable` is placed first, any strike, or a disqualification.
CREATE FUNCTION notification_category_spec()
RETURNS TABLE (category text, ord int, locked boolean, admin_only boolean,
               app boolean, push boolean, levels text[], level text)
LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES
      ('submissions', 1, true,  false, true, true,  NULL::text[],                   NULL::text),
      ('matches',     2, false, false, true, false, ARRAY['all', 'notable', 'off'], 'notable'),
      ('ratings',     3, false, false, true, false, NULL,                           NULL),
      ('season',      4, false, false, true, true,  NULL,                           NULL),
      ('account',     5, true,  false, true, true,  NULL,                           NULL),
      ('admin',       6, false, true,  true, true,  NULL,                           NULL)
    ) AS t (category, ord, locked, admin_only, app, push, levels, level);
$$;

CREATE FUNCTION notification_category_ok(p_category text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT EXISTS (SELECT 1 FROM notification_category_spec() s WHERE s.category = p_category);
$$;

-- A stored setting is a category that exists, a locked category that is still on, and a level
-- from that category's own vocabulary -- or none, where it has none.
CREATE FUNCTION notification_setting_ok(p_category text, p_app boolean, p_level text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT EXISTS (SELECT 1 FROM notification_category_spec() s
                    WHERE s.category = p_category
                      AND (p_app OR NOT s.locked)
                      AND CASE WHEN s.levels IS NULL THEN p_level IS NULL
                               ELSE p_level = ANY (s.levels) END);
$$;

-- ONLY WHAT A COMPETITOR CHANGED. A row exists once PATCH /v1/me/notification-settings has written
-- one, and it holds the whole category -- the route merges a partial body into the effective
-- setting -- so a later change to a DEFAULT in the spec reaches everyone who never touched that
-- category, and nobody who did.
CREATE TABLE notification_settings (
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    category    text        NOT NULL,
    app         boolean     NOT NULL,
    push        boolean     NOT NULL,
    level       text,
    updated_at  timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, category),
    CONSTRAINT notification_settings_shape CHECK (notification_setting_ok(category, app, level))
);

-- THE EFFECTIVE SETTINGS, stored or defaulted, for the categories this account can receive. Two
-- routes return them and every writer asks them, so there is one definition of "is this on".
-- A baseline receives nothing: it never signs in, and a row addressed to it is a row nobody reads.
-- A locked category reads `app` true whatever is stored, which the CHECK already guarantees.
CREATE FUNCTION notification_settings_of(p_user uuid)
RETURNS TABLE (category text, ord int, app boolean, push boolean, locked boolean, level text)
LANGUAGE sql STABLE AS $$
    SELECT sp.category, sp.ord,
           sp.locked OR coalesce(ns.app, sp.app),
           coalesce(ns.push, sp.push),
           sp.locked,
           CASE WHEN sp.levels IS NOT NULL THEN coalesce(ns.level, sp.level) END
      FROM users u
     CROSS JOIN notification_category_spec() sp
      LEFT JOIN notification_settings ns ON ns.user_id = u.id AND ns.category = sp.category
     WHERE u.id = p_user
       AND u.role <> 'baseline'
       AND (NOT sp.admin_only OR u.role = 'admin');
$$;

-- The settings object both settings routes answer with, in the spec's order.
CREATE FUNCTION notification_settings_json(p_user uuid) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_agg(json_build_object(
               'category', s.category, 'app', s.app, 'push', s.push,
               'locked', s.locked, 'level', s.level) ORDER BY s.ord), '[]'::json)
      FROM notification_settings_of(p_user) s;
$$;

-- WHETHER ONE NOTIFICATION REACHES ONE ACCOUNT, asked inside every writer's INSERT and nowhere
-- else. A writer never inserts a row the settings say to skip, so the feed needs no second filter
-- and a category turned back on does not surface what was skipped while it was off.
--
-- `p_notable` is the writer's own judgement of the item and matters only where a category has a
-- level: `all` takes everything, `notable` takes what the writer marked notable, `off` nothing.
-- No row -- an unknown category, `admin` for a competitor, any category for a baseline -- is false.
CREATE FUNCTION notification_wanted(p_user uuid, p_category text, p_notable boolean DEFAULT false)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT s.app AND (s.level IS NULL
                                       OR s.level = 'all'
                                       OR (s.level = 'notable' AND coalesce(p_notable, false)))
                       FROM notification_settings_of(p_user) s
                      WHERE s.category = p_category), false);
$$;

-- ONE ROW PER THING SAID TO ONE ACCOUNT. Written where the platform DECIDES the thing -- the admit
-- and count clocks, the season close, sign-in, the token exchange -- and never derived later, so a
-- notification states a decision that happened rather than a guess at one.
--
-- The columns are the page's, not the event's: `subject`, `description` and `link` are rendered as
-- given, `kind` picks an icon family and `tone` a colour, and `data` carries the numbers a richer
-- row draws (a place, a score, a rating change, a reason code). The ids are there so a page can
-- group or deep-link without parsing `link`; they are SET NULL rather than cascading because a
-- message about a thing outlives the thing -- and nothing here deletes one anyway.
--
-- `dedupe_key` IS THE IDEMPOTENCE, and it is a key rather than a hope. Clocks replay whole task
-- lists every sweep, retry occurrences, and learn nothing from a statement but rows_affected -- so
-- every writer is `INSERT ... ON CONFLICT (user_id, dedupe_key) DO NOTHING`, keyed on what the
-- notification is about (`version:<id>:<status>`, `result:<match>:<seat>`), and running it twice
-- inserts once. A writer that cannot name its event in a key is not idempotent.
CREATE TABLE notifications (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    category    text        NOT NULL,
    kind        text        NOT NULL,
    tone        text        NOT NULL DEFAULT 'info',
    icon        text,                    -- overrides the kind's default icon; null nearly always

    subject     text        NOT NULL,
    description text,
    link        text,                    -- an application path: '/matches/<id>', never a URL

    game        text,                    -- the slug
    season      int,
    model_id    uuid        REFERENCES models (id) ON DELETE SET NULL,
    version_id  uuid        REFERENCES model_versions (id) ON DELETE SET NULL,
    match_id    uuid        REFERENCES matches (id) ON DELETE SET NULL,
    actor       text,                    -- a handle the item is about, for an avatar

    data        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    dedupe_key  text        NOT NULL,

    created_at  timestamptz NOT NULL DEFAULT now(),
    read_at     timestamptz,

    CONSTRAINT notifications_dedupe_uniq      UNIQUE (user_id, dedupe_key),
    CONSTRAINT notifications_category_known   CHECK (notification_category_ok(category)),
    CONSTRAINT notifications_kind_known
        CHECK (kind IN ('progress', 'result', 'rank', 'alert', 'season', 'account')),
    CONSTRAINT notifications_tone_known       CHECK (tone IN ('info', 'ok', 'warn', 'bad')),
    CONSTRAINT notifications_icon_shape
        CHECK (icon IS NULL OR icon ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    CONSTRAINT notifications_subject_shape    CHECK (btrim(subject) <> '' AND length(subject) <= 200),
    CONSTRAINT notifications_description_size CHECK (description IS NULL OR length(description) <= 1000),
    -- AN APPLICATION PATH AND NOTHING ELSE. `//host/x` is a path to the site's router and a
    -- protocol-relative URL to an address bar, so the second character is refused too: a
    -- notification must never be a way to send a competitor somewhere that is not this site.
    CONSTRAINT notifications_link_is_a_path
        CHECK (link IS NULL OR (left(link, 1) = '/' AND left(link, 2) <> '//' AND length(link) <= 500)),
    CONSTRAINT notifications_season_positive  CHECK (season IS NULL OR season >= 1),
    CONSTRAINT notifications_data_object      CHECK (jsonb_typeof(data) = 'object'),
    CONSTRAINT notifications_dedupe_shape
        CHECK (btrim(dedupe_key) <> '' AND length(dedupe_key) <= 200)
);

-- The feed, newest first, and the keyset cursor over it. The trailing id makes the order total: one
-- clock statement writes many rows sharing one now(), and a page boundary that is not total repeats
-- or skips a row.
CREATE INDEX notifications_feed_idx
    ON notifications (user_id, created_at DESC, id DESC);

-- The bell. Every feed response carries the unread count across all categories, so this is read on
-- every poll: partial on `read_at IS NULL`, it holds only what is unread and shrinks as it is read.
-- It also serves the Unread tab's page, in the same order.
CREATE INDEX notifications_unread_idx
    ON notifications (user_id, created_at DESC, id DESC)
    WHERE read_at IS NULL;

-- NOTHING PRUNES THIS TABLE, and no clock may: the clocks delete nothing, by review and by
-- `soma-db`'s `operations.delete = false`. Retention is open (README Status); when it is chosen it
-- is a DELETE over read rows past an age, and it needs a writer that is not a clock.

COMMIT;
