SELECT json_build_object( 'handle', u.handle, 'display_name', u.display_name, 'bio', u.bio, 'role', u.role,
        'baseline', u.role = 'baseline', 'created_at', u.created_at, 'medals', coalesce((SELECT json_agg(json_build_object(
                        'game', mg.slug, 'season', ms.slug, 'season_name', ms.name, 'ladder', p.ladder, 'place',
                        p.place, 'model_id', me.id, 'model', me.name, 'version', mv.version)
                ORDER BY ms.closed_at DESC, p.ladder, p.place)
            FROM season_podium p
            JOIN seasons ms ON ms.id = p.season_id
            JOIN games mg ON mg.id = ms.game_id
            JOIN model_versions mv ON mv.id = p.version_id
            JOIN models me ON me.id = mv.model_id
            WHERE p.owner_id = u.id), '[]'::json), 'games', coalesce((SELECT json_agg(x.section
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
                            'retired', e.retired_at IS NOT NULL, 'latest_match', match_ref_json((SELECT m.id
                                FROM model_versions lv
                                CROSS JOIN LATERAL (SELECT ev.match_id FROM rating_events ev
                                                     WHERE ev.version_id = lv.id AND ev.ladder = 'open' AND ev.seq > 0
                                                     ORDER BY ev.seq DESC LIMIT 1) le
                                JOIN matches m ON m.id = le.match_id
                                WHERE lv.model_id = e.id
                                AND lv.season_id = v.season_id
                                AND match_counted(m)
                                ORDER BY m.played_at DESC, m.id DESC
                                LIMIT 1)), 'versions', json_agg(json_build_object(
                            'version_id', v.id, 'version', v.version, 'class', v.weight_class, 'size_bytes',
                            v.size_bytes, 'memory_bytes', v.memory_bytes, 'status', v.status, 'created_at', v.created_at, 'ratings',
                            model_ratings(v.id, ($2)::float8))
                        ORDER BY v.version DESC)) AS model
                    FROM model_versions v
                    WHERE v.model_id = e.id
                    AND version_public(v.status)
                    GROUP BY v.season_id, e.name, e.id ) y ON true
                JOIN seasons se ON se.id = y.season_id
                WHERE e.owner_id = u.id
                GROUP BY g.slug, g.name, se.id) x), '[]'::json) ) AS body
FROM users u
WHERE lower(u.handle) = lower(($1)::text)
