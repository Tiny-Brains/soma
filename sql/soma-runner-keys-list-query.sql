SELECT coalesce(json_agg(json_build_object('id', k.id, 'label', k.label, 'key_prefix', k.key_prefix,
                'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
                'runners', (SELECT count(*)
                FROM runners r
                WHERE r.key_id = k.id
                AND r.revoked_at IS NULL))
        ORDER BY k.created_at DESC), '[]'::json) AS body
FROM runner_keys k
WHERE k.user_id = ($1)::uuid
