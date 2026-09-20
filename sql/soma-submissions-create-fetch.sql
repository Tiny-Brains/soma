SELECT json_build_object('version_id', v.id, 'model_id', e.id, 'model', e.name, 'version', v.version,
        'status', v.status, 'season', se.slug, 'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash)
    AS body
FROM model_versions v
JOIN models e ON e.id = v.model_id
JOIN games g ON g.id = e.game_id
JOIN seasons se ON se.id = v.season_id
AND se.closed_at IS NULL
JOIN live_sessions s ON s.sid = ($4)::uuid
AND s.user_id = e.owner_id
WHERE e.owner_id = ($1)::uuid
AND g.slug = ($2)::text
AND e.id = ($3)::uuid
AND v.status = 'testing'
AND v.weights_hash = ($5)::text
