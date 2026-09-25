WITH changed AS (UPDATE users t
SET role = ($3)::user_role
FROM live_sessions ls
JOIN users me ON me.id = ls.user_id
AND me.role = 'admin'
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
AND t.id = ($4)::uuid
AND t.id <> me.id
AND t.role <> 'baseline'
AND t.role <> ($3)::user_role
    RETURNING t.id, t.handle, t.role)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($1)::uuid, 'user.role', 'user', changed.handle, jsonb_build_object('role', changed.role)
FROM changed
