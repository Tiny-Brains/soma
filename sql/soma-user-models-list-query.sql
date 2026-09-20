SELECT (SELECT coalesce(json_agg(x
            ORDER BY x.created_at DESC), '[]'::json)
    FROM (
        SELECT e.id, e.name, u.handle AS owner, g.slug AS game, e.created_at, e.retired_at IS NOT
            NULL AS retired, (SELECT coalesce(json_agg(json_build_object( 'version_id', v.id, 'version',
                            v.version, 'class', v.weight_class, 'size_bytes', v.size_bytes, 'status',
                            v.status, 'phase', model_phase(v), 'reject_reason', v.reject_reason, 'created_at',
                            v.created_at, 'season', (SELECT se.slug
                        FROM seasons se
                        WHERE se.id = v.season_id), 'ratings', model_ratings(v.id, ($4)::float8),
                            'last_played_at', (SELECT max(mt.played_at)
                        FROM match_seats ms
                        JOIN matches mt ON mt.id = ms.match_id
                        WHERE ms.version_id = v.id))
                    ORDER BY v.version DESC), '[]'::json)
            FROM model_versions v
            WHERE v.model_id = e.id) AS versions
        FROM models e
        JOIN users u ON u.id = e.owner_id
        JOIN games g ON g.id = e.game_id
        WHERE e.owner_id = ($1)::uuid
        AND (($2)::text IS NULL
            OR g.slug = ($2)::text)) x) AS body, ls.sid AS session_ok
FROM live_sessions ls
WHERE ls.sid = ($3)::uuid
AND ls.user_id = ($1)::uuid
