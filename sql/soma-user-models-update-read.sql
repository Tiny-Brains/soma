SELECT json_build_object('model_id', e.id, 'model', e.name, 'game', g.slug, 'owner', u.handle, 'created_at',
        e.created_at, 'retired', e.retired_at IS NOT NULL, 'retired_at', e.retired_at) AS body
FROM models e
JOIN games g ON g.id = e.game_id
JOIN users u ON u.id = e.owner_id
WHERE e.id = ($1)::uuid
AND e.owner_id = ($2)::uuid
