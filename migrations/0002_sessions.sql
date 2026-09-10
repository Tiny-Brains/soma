-- Soma -- server-side sessions, so signing out means something.
--
-- The `soma_session` token carries a `sid` claim naming a row here, and every authed statement
-- JOINs `live_sessions` on it, so marking a row revoked ends the token before its 30-day `exp`.
-- The check is a join rather than a guard task on purpose: a JSONLogic guard fails open if it is
-- ever wrong, and a halted task answers 400 where the shell needs 401. The rule is enforced by the
-- same engine that enforces one-active-version, and the workflow only shapes the 401.
--
-- Applied by /docker-entrypoint-initdb.d on a fresh volume; on an existing one, by hand:
--   docker compose exec -T db psql -U soma -d soma < soma/migrations/0002_sessions.sql

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

COMMIT;
