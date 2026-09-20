SELECT json_build_object( 'admission', json_build_object( 'version_id', a.version_id, 'model', ($2)::text
            || a.version_id::text, 'registration', a.registration, 'artifact', json_build_object('key',
                v.artifact_key, 'digest', v.weights_hash), 'budget_ops', a.budget_ops, 'infer_ms',
            ($4)::int, 'attempt', a.attempts, 'observations', CASE
        WHEN jsonb_typeof(g.reference_observations) = 'array' THEN (SELECT coalesce(jsonb_agg(o.obs
                    ORDER BY o.n), '[]'::jsonb)
            FROM jsonb_array_elements(g.reference_observations)
            WITH ORDINALITY AS o (obs, n)
            WHERE o.n <= ($3)::int)
        ELSE '[]'::jsonb
        END), 'lease_expires_at', a.lease_expires_at) AS body
FROM admissions a
JOIN model_versions v ON v.id = a.version_id
JOIN games g ON g.id = v.game_id
WHERE a.claim_token = ($1)::uuid
