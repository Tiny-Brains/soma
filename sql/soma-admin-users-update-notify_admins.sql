INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, actor, data,
        dedupe_key)
SELECT a.id, 'admin', 'account', 'info', '@' || left(t.handle, 64) || CASE
WHEN t.role = 'admin' THEN ' is now an administrator'
ELSE ' is no longer an administrator'
END, 'Changed by @' || left(me.handle, 64) || '.', '/admin/users', t.handle, jsonb_build_object('handle',
        t.handle, 'role', t.role, 'by', me.handle), 'role:' || ($3)::uuid
FROM users t
JOIN users me ON me.id = ($2)::uuid
JOIN users a ON a.role = 'admin'
AND a.id <> t.id
AND a.id <> me.id
WHERE t.id = ($1)::uuid
AND t.role = ($4)::user_role
AND notification_wanted(a.id, 'admin')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
