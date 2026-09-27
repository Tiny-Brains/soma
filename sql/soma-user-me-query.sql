-- WHO YOU ARE, and the session entry's terms. The JOIN on live_sessions is the fence: no row is a
-- signed-out session or a deleted user. `expires_at` is the session's, rendered in the shape
-- {"now": []} answers (UTC, milliseconds, Z), so the cached entry can be compared with now as text.
-- No `candidates` here: they move with every admit tick, which cannot name the user, so they have
-- their own route (soma-user-me-candidates) and this body can be cached per session.
SELECT json_build_object('id', u.id, 'handle', u.handle, 'display_name', u.display_name, 'bio', u.bio,
        'role', u.role, 'created_at', u.created_at, 'comments_off_until', commenting_off_until(u),
        'comments_off_reason', commenting_off_reason(u),
        -- The seasons this account administers (A5): a membership in season_admins, not a role, so a
        -- competitor may administer several and compete in others. web draws the season-admin desk
        -- from this and gates each page on it; the routes themselves re-check the membership off the
        -- row on every call, so this is UI state, not the fence. Assigning or removing an admin bumps
        -- this account's session generation so the entry is re-read. Newest season first.
        'admin_of', coalesce((SELECT json_agg(json_build_object(
                        'game', g.slug, 'season', se.slug, 'name', se.name, 'state', season_state(se))
                        ORDER BY se.created_at DESC)
                      FROM season_admins sa
                      JOIN seasons se ON se.id = sa.season_id
                      JOIN games g    ON g.id = se.game_id
                     WHERE sa.user_id = u.id AND sa.removed_at IS NULL), '[]'::json)) AS body,
       s.last_seen_at < now() - interval '5 minutes' AS touch_due,
       to_char(s.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS expires_at
FROM users u
JOIN live_sessions s ON s.user_id = u.id
AND s.sid = ($2)::uuid
WHERE u.id = ($1)::uuid
