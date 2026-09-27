-- live_runners is the outer FROM: a revoked key, a revoked runner or a demoted owner gets no row,
-- which the route answers 401, and a live idle runner gets {n: 0, items: []}. The aggregate sits in
-- a subquery so the two cases stay apart -- json_agg without GROUP BY would answer a row regardless.
SELECT (SELECT json_build_object('n', count(*), 'items', coalesce(json_agg(json_build_object('model', ($1)::text
                    || v.id::text, 'version_id', v.id, 'digest', v.weights_hash, 'key', v.artifact_key,
                    'manifest', jsonb_build_object('abi', v.manifest::jsonb -> 'abi', 'name', to_jsonb(($1)::text
                            || v.id::text), 'version', coalesce(v.manifest::jsonb -> 'version', '"1"'::jsonb),
                        'format', coalesce(v.manifest::jsonb -> 'format', '"onnx"'::jsonb), 'description',
                        coalesce(v.manifest::jsonb -> 'description', '""'::jsonb), 'inputs', v.manifest::jsonb
                        -> 'inputs', 'outputs', v.manifest::jsonb -> 'outputs', 'probe_dims', coalesce(v.manifest::jsonb
                            -> 'probe_dims', '{}'::jsonb)), 'status', v.status)
            ORDER BY v.created_at), '[]'::json)) AS body
    FROM model_versions v
    WHERE v.status IN ('verified', 'active')
AND v.manifest IS NOT NULL
AND v.artifact_key IS NOT NULL
AND v.weights_hash IS NOT NULL
-- ONLY THE SEASONS THIS KEY CAN BE ASKED TO PLAY (N30). A season key's roster is its own season's
-- versions (and only while that season lets its own fleet play); a platform key's is every season
-- the platform may play. A season runner's memory then holds its season's models alone.
AND EXISTS (SELECT 1 FROM seasons se
    WHERE se.id = v.season_id
    AND CASE WHEN lr.season_id IS NOT NULL
             THEN se.id = lr.season_id AND (se.fleet ->> 'matches') IN ('own', 'both')
             ELSE (se.fleet ->> 'matches') IN ('platform', 'both')
        END)
AND EXISTS (SELECT 1
    FROM match_seats s
    WHERE s.version_id = v.id)) AS body
FROM live_runners lr
WHERE lr.id = ($2)::uuid
