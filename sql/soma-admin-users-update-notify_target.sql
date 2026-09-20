INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, actor, data,
        dedupe_key)
SELECT t.id, 'account', 'account', CASE
WHEN t.role = 'admin' THEN 'ok'
ELSE 'warn'
END, CASE
WHEN t.role = 'admin' THEN 'You are now an administrator'
ELSE 'You are no longer an administrator'
END, 'Changed by @' || left(me.handle, 64) || '.', CASE
WHEN t.role = 'admin' THEN '/admin/seasons'
ELSE '/me/account'
END, me.handle, jsonb_build_object('role', t.role, 'by', me.handle), 'role:' || ($3)::uuid
FROM users t
JOIN users me ON me.id = ($2)::uuid
WHERE t.id = ($1)::uuid
AND t.role = ($4)::user_role
AND notification_wanted(t.id, 'account')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
