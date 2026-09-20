SELECT json_build_object( 'model_id', e.id, 'model', e.name, 'owner', e.owner_id, 'owner_handle',
        u.handle, 'baseline', u.role = 'baseline', 'game', g.slug, 'created_at', e.created_at, 'retired',
        e.retired_at IS NOT NULL, 'retired_at', e.retired_at, 'versions', coalesce((SELECT json_agg(json_build_object(
                        'version_id', v.id, 'version', v.version, 'class', v.weight_class, 'size_bytes',
                        v.size_bytes, 'param_count', v.param_count, 'infer_us', v.infer_us, 'status',
                        v.status, 'phase', model_phase(v), 'reject_reason', v.reject_reason, 'created_at',
                        v.created_at, 'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash,
                        'season', (SELECT se.slug
                        FROM seasons se
                        WHERE se.id = v.season_id), 'ratings', model_ratings(v.id, ($2)::float8),
                        'last_played_at', (SELECT max(mt.played_at)
                        FROM match_seats ms
                        JOIN matches mt ON mt.id = ms.match_id
                        WHERE ms.version_id = v.id))
                ORDER BY v.version DESC)
            FROM model_versions v
            WHERE v.model_id = e.id), '[]'::json)) AS body
FROM models e
JOIN users u ON u.id = e.owner_id
JOIN games g ON g.id = e.game_id
WHERE e.id = ($1)::uuid
