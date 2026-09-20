SELECT json_build_object( 'season', se.slug, 'maps', coalesce((SELECT json_agg(CASE
                WHEN ($4)::text = 'true' THEN (season_map_json(sm)::jsonb || jsonb_build_object('board',
                            sm.board))::json
                ELSE season_map_json(sm)
                END
                ORDER BY sm.added_at, sm.map_id)
            FROM season_maps sm
            WHERE sm.season_id = se.id
            AND (($3)::text IS DISTINCT
                FROM 'true'
                OR sm.enabled)), '[]'::json)) AS body
FROM seasons se
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
