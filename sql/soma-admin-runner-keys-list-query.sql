-- EVERY RUNNER KEY, for the platform admin: their own, other admins', and every season admin's
-- season key, newest first. `mine` marks the caller's own; `season` names a season key's season.
SELECT coalesce(json_agg(json_build_object('id', k.id, 'label', k.label, 'key_prefix', k.key_prefix,
                'owner', u.handle, 'mine', k.user_id = ($1)::uuid, 'season', se.slug,
                'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
                'runners', (SELECT count(*)
                FROM runners r
                WHERE r.key_id = k.id
                AND r.revoked_at IS NULL))
        ORDER BY k.created_at DESC), '[]'::json) AS body
FROM runner_keys k
JOIN users u ON u.id = k.user_id
LEFT JOIN seasons se ON se.id = k.season_id
