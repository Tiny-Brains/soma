SELECT ls.sid AS session_ok, json_build_object('id', u.id, 'handle', u.handle, 'display_name', u.display_name,
        'role', u.role, 'created_at', u.created_at) AS body
FROM live_sessions ls
JOIN users u ON u.id = ls.user_id
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
