SELECT coalesce(json_agg(json_build_object('id', r.id, 'label', r.label, 'key_id', r.key_id, 'key_label',
                k.label, 'key_prefix', k.key_prefix, 'owner', u.handle, 'engine_digest', r.engine_digest,
                'node_version', r.node_version, 'orion_version', r.orion_version, 'ops_budget', r.ops_budget,
                'arch', r.arch, 'max_in_flight', r.max_in_flight, 'first_seen_at', r.first_seen_at,
                'last_seen_at', r.last_seen_at, 'revoked_at', r.revoked_at, 'live', (r.revoked_at
                    IS NULL
                AND k.revoked_at IS NULL
                AND u.role = 'admin'), 'in_flight', (SELECT count(*)
                FROM matches m
                WHERE m.played_by = r.id
                AND m.status IN ('claimed', 'running')), 'played', (SELECT count(*)
                FROM matches m
                WHERE m.played_by = r.id
                AND m.status IN ('finished', 'rated')))
        ORDER BY r.last_seen_at DESC), '[]'::json) AS body
FROM runners r
JOIN runner_keys k ON k.id = r.key_id
JOIN users u ON u.id = k.user_id
