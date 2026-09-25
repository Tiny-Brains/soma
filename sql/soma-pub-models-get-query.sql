SELECT json_build_object( 'model_id', e.id, 'model', e.name, 'owner', e.owner_id, 'owner_handle',
        u.handle, 'baseline', u.role = 'baseline', 'game', g.slug, 'created_at', e.created_at, 'retired',
        e.retired_at IS NOT NULL, 'retired_at', e.retired_at, 'versions', coalesce((SELECT json_agg(version_json(v,
                    ($2)::float8)
                ORDER BY v.version DESC)
            FROM model_versions v
            WHERE v.model_id = e.id
            AND version_public(v.status)), '[]'::json)) AS body
FROM models e
JOIN users u ON u.id = e.owner_id
JOIN games g ON g.id = e.game_id
WHERE e.id = ($1)::uuid
