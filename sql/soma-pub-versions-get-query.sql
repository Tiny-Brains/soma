SELECT json_build_object( 'id', v.id, 'model_id', e.id, 'model', e.name, 'owner', u.handle, 'game',
        g.slug, 'version', v.version, 'class', v.weight_class, 'class_max_bytes', (SELECT (x ->> 'max_bytes')::bigint
        FROM seasons cse, jsonb_array_elements(cse.weight_classes) AS x
        WHERE cse.id = v.season_id
        AND x ->> 'class' = v.weight_class::text), 'size_bytes', v.size_bytes, 'param_count', v.param_count,
        'infer_us', v.infer_us, 'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash,
        'orion_version', v.orion_version, 'status', v.status, 'phase', model_phase(v), 'admit_attempt',
        CASE
    WHEN v.status = 'testing' THEN (SELECT a.attempts
        FROM admissions a
        WHERE a.version_id = v.id)
    END, 'successor', (SELECT s.version
        FROM model_versions s
        WHERE s.model_id = v.model_id
        AND s.season_id = v.season_id
        AND s.status = 'active'
        AND v.status = 'superseded'), 'reject_reason', v.reject_reason, 'created_at', v.created_at,
        'season', (SELECT se.slug
        FROM seasons se
        WHERE se.id = v.season_id), 'trial', (SELECT json_build_object('match_id', t.id, 'status',
                t.status, 'map', (SELECT sm.map_id
                FROM season_maps sm
                WHERE sm.id = t.season_map_id), 'queued_at', t.created_at, 'waiting_s', CASE
            WHEN t.status = 'pending' THEN round(extract(epoch
                    FROM now() - t.created_at))::bigint
            END)
        FROM matches t
        WHERE t.trial_version_id = v.id
        ORDER BY t.created_at DESC
        LIMIT 1), 'ratings', model_ratings(v.id, ($2)::float8), 'baseline', u.role = 'baseline', 'last_played_at',
        (SELECT max(mt.played_at)
        FROM match_seats ms
        JOIN matches mt ON mt.id = ms.match_id
        WHERE ms.version_id = v.id)) AS body
FROM model_versions v
JOIN models e ON e.id = v.model_id
JOIN users u ON u.id = e.owner_id
JOIN games g ON g.id = e.game_id
WHERE v.id = ($1)::uuid
