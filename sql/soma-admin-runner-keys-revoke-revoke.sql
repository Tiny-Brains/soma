WITH revoked AS (UPDATE runner_keys k
    SET revoked_at = now()
    FROM users u
    JOIN live_sessions s ON s.user_id = u.id
    AND s.sid = ($3)::uuid
    WHERE k.id = ($2)::uuid
    AND k.user_id = u.id
    AND u.id = ($1)::uuid
    AND u.role = 'admin'
    AND k.revoked_at IS NULL
    RETURNING k.id, k.label, k.key_prefix)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($1)::uuid, 'runner_key.revoke', 'runner_key', revoked.id::text, jsonb_build_object('label', revoked.label,
        'prefix', revoked.key_prefix)
FROM revoked
