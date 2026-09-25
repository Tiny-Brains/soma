WITH made AS (INSERT INTO runner_keys (user_id, label, key_hash, key_prefix)
SELECT u.id, btrim(($2)::text),
($3)::text, ($4)::text
FROM users u
JOIN live_sessions s ON s.user_id = u.id
AND s.sid = ($5)::uuid
WHERE u.id = ($1)::uuid
AND u.role = 'admin'
AND btrim(($2)::text) <> ''
    RETURNING id, label, key_prefix)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($1)::uuid, 'runner_key.create', 'runner_key', made.id::text, jsonb_build_object('label', made.label,
        'prefix', made.key_prefix)
FROM made
