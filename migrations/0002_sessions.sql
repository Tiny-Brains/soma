-- Soma — server-side sessions, so signing out means something
--
-- Until this table existed, `soma_session` was a bare 30-day JWT: DELETE /v1/session
-- cleared the cookie and the token stayed valid to `exp`, so a stolen one was good
-- for a month and there was no way to end it.
--
-- The token now carries a `sid` claim naming a row here, and every authed statement
-- JOINs `live_sessions` on it. The check is a join rather than a guard task on
-- purpose: a JSONLogic guard fails open if it is ever wrong, and a halted task
-- (Orion 1.6's `halt_on: "failure"`) answers 400 where the shell needs 401. So the
-- rule is enforced where it cannot be forgotten -- in SQL, by the same engine that
-- enforces the one-active-version and one-in-flight rules -- and the workflow's
-- only job is to notice the empty result and shape the 401.
--
-- Applied by /docker-entrypoint-initdb.d on a fresh volume. On a volume that already
-- exists, apply it by hand:
--
--   docker compose exec -T db psql -U soma -d soma < soma/migrations/0002_sessions.sql

BEGIN;

-- One row per sign-in. `sid` is minted by the callback workflow ({"random": ["uuid"]})
-- and is not derivable from the token's other claims, which is the point: two sign-ins
-- by the same user in the same second are otherwise indistinguishable.
--
-- ON DELETE CASCADE is the second half of revocation: deleting a user ends their
-- sessions, rather than leaving live tokens naming a row that is gone.
CREATE TABLE sessions (
    sid         uuid        PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    issued_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz
);

-- `expires_at` duplicates the token's own `exp`, which Orion already enforces at the
-- channel. It is kept because the two are minted from different clocks by different
-- code, and a row that outlives its token is a lie about what is signed in. The
-- callback sets it to match jwt_sign's `expires_in`.
--
-- The predicate lives in a view so it is written once. Every authed statement joins
-- this, never the table.
CREATE VIEW live_sessions AS
    SELECT sid, user_id
    FROM sessions
    WHERE revoked_at IS NULL
      AND expires_at > now();

-- "Sign out everywhere", and the lookup behind any future session list.
CREATE INDEX sessions_user_live_idx
    ON sessions (user_id)
    WHERE revoked_at IS NULL;

-- Nothing prunes this table. Rows are ~60 bytes and expire in 30 days; at M0 the
-- ladder is hundreds of competitors, so it is left to grow deliberately rather than
-- given a scheduler. The housekeeping statement, when it is worth running, is:
--
--   DELETE FROM sessions WHERE expires_at < now() - interval '30 days';

COMMIT;
