-- A PLATFORM ADMIN REVOKES ANY KEY: their own, another admin's, or a season admin's season key --
-- the one fence on a credential whose owner has gone quiet. The caller is re-read as a live admin
-- inside the statement. Audited.
WITH revoked AS (UPDATE runner_keys k
    SET revoked_at = now()
    FROM users u
    JOIN live_sessions s ON s.user_id = u.id
    AND s.sid = ($3)::uuid
    WHERE k.id = ($2)::uuid
    AND u.id = ($1)::uuid
    AND u.role = 'admin'
    AND k.revoked_at IS NULL
    RETURNING k.id, k.label, k.key_prefix, k.season_id)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($1)::uuid, 'runner_key.revoke', 'runner_key', revoked.id::text, jsonb_build_object('label', revoked.label,
        'prefix', revoked.key_prefix, 'season_id', revoked.season_id)
FROM revoked
