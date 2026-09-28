-- Mint a SEASON-BOUND runner key (N30), on the season's admin page. The season id comes from the
-- season-admin-only fragment ($6); the key's owner is the caller ($1), a season admin or a platform
-- admin -- either way live_runner_keys binds the key's reach to this season and the fleet predicate
-- keeps a season runner to its own season. The live_sessions JOIN is the revoked-session fence, the
-- same window the platform mint guards.
WITH made AS (
    INSERT INTO runner_keys (user_id, season_id, label, key_hash, key_prefix)
    SELECT u.id, ($6)::uuid, btrim(($2)::text), ($3)::text, ($4)::text
    FROM users u
    JOIN live_sessions s ON s.user_id = u.id AND s.sid = ($5)::uuid
    WHERE u.id = ($1)::uuid
    AND btrim(($2)::text) <> ''
    RETURNING id, label, key_prefix)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($1)::uuid, 'runner_key.create', 'runner_key', made.id::text,
       jsonb_build_object('label', made.label, 'prefix', made.key_prefix,
                          'game', ($8)::text, 'season', ($7)::text)
FROM made
