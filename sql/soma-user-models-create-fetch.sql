SELECT json_build_object('model_id', e.id, 'model', e.name, 'game', g.slug, 'owner', u.handle, 'created_at',
        e.created_at, 'versions', '[]'::json) AS body
FROM models e
JOIN games g ON g.id = e.game_id
JOIN users u ON u.id = e.owner_id
JOIN live_sessions s ON s.sid = ($4)::uuid
AND s.user_id = e.owner_id
WHERE e.owner_id = ($1)::uuid
AND g.slug = ($2)::text
AND lower(e.name) = lower(btrim(($3)::text))
