SELECT json_build_object('id', u.id, 'handle', u.handle, 'display_name', u.display_name, 'role', u.role,
        'created_at', u.created_at, 'candidates', coalesce((SELECT json_agg(json_build_object('version_id',
                        v.id, 'model_id', e.id, 'model', e.name, 'game', g.slug, 'version', v.version,
                        'phase', model_phase(v))
                ORDER BY g.slug, e.name)
            FROM model_versions v
            JOIN models e ON e.id = v.model_id
            JOIN games g ON g.id = e.game_id
            WHERE e.owner_id = u.id
            AND v.status IN ('testing', 'verified')), '[]'::json)) AS body
FROM users u
JOIN live_sessions s ON s.user_id = u.id
AND s.sid = ($2)::uuid
WHERE u.id = ($1)::uuid
