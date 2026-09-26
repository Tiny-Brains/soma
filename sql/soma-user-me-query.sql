-- WHO YOU ARE, and the session entry's terms. The JOIN on live_sessions is the fence: no row is a
-- signed-out session or a deleted user. `expires_at` is the session's, rendered in the shape
-- {"now": []} answers (UTC, milliseconds, Z), so the cached entry can be compared with now as text.
-- No `candidates` here: they move with every admit tick, which cannot name the user, so they have
-- their own route (soma-user-me-candidates) and this body can be cached per session.
SELECT json_build_object('id', u.id, 'handle', u.handle, 'display_name', u.display_name, 'bio', u.bio,
        'role', u.role, 'created_at', u.created_at, 'comments_off_until', commenting_off_until(u),
        'comments_off_reason', commenting_off_reason(u)) AS body,
       s.last_seen_at < now() - interval '5 minutes' AS touch_due,
       to_char(s.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at
FROM users u
JOIN live_sessions s ON s.user_id = u.id
AND s.sid = ($2)::uuid
WHERE u.id = ($1)::uuid
