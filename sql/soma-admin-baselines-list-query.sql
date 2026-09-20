SELECT json_build_object( 'season', se.slug, 'baselines', coalesce((SELECT json_agg(season_baseline_json(v)
                ORDER BY v.created_at, v.id)
            FROM model_versions v
            JOIN models e ON e.id = v.model_id
            JOIN users u ON u.id = e.owner_id
            AND u.role = 'baseline'
            WHERE v.season_id = se.id), '[]'::json)) AS body
FROM seasons se
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
