-- SHARED by the public route (no session: $5 and $6 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
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
AND season_visible(se, session_viewer(($5)::uuid, ($6)::uuid))
