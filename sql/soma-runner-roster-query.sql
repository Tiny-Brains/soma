SELECT json_build_object('n', count(*), 'items', coalesce(json_agg(json_build_object('model', ($1)::text
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
AND EXISTS (SELECT 1
    FROM match_seats s
    WHERE s.version_id = v.id)
