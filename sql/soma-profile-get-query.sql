SELECT json_build_object( 'handle', u.handle, 'display_name', u.display_name, 'role', u.role, 'baseline',
        u.role = 'baseline', 'created_at', u.created_at, 'games', coalesce((SELECT json_agg(x.section
                ORDER BY x.game, x.season_number DESC)
            FROM (
                SELECT g.slug AS game, se.number AS season_number, json_build_object( 'game', g.slug,
                        'game_name', g.name, 'season', se.slug, 'season_name', se.name, 'season_state',
                        season_state(se), 'models', json_agg(y.model
                        ORDER BY y.name)) AS section
                FROM models e
                JOIN games g ON g.id = e.game_id
                JOIN LATERAL (
                    SELECT v.season_id, e.name, json_build_object( 'model_id', e.id, 'model', e.name,
                            'retired', e.retired_at IS NOT NULL, 'versions', json_agg(json_build_object(
                            'version_id', v.id, 'version', v.version, 'class', v.weight_class, 'size_bytes',
                            v.size_bytes, 'status', v.status, 'created_at', v.created_at, 'ratings',
                            model_ratings(v.id, ($2)::float8))
                        ORDER BY v.version DESC)) AS model
                    FROM model_versions v
                    WHERE v.model_id = e.id
                    AND v.status IN ('active', 'disabled', 'superseded')
                    GROUP BY v.season_id, e.name, e.id ) y ON true
                JOIN seasons se ON se.id = y.season_id
                WHERE e.owner_id = u.id
                GROUP BY g.slug, g.name, se.id) x), '[]'::json) ) AS body
FROM users u
WHERE lower(u.handle) = lower(($1)::text)
