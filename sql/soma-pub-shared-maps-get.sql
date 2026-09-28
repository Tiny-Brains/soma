-- SHARED by the public route (no session: $4 and $5 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
SELECT (season_map_json(sm)::jsonb || jsonb_build_object( 'season', se.slug, 'board', sm.board, 'events',
            coalesce((SELECT jsonb_agg(jsonb_build_object('at', ev.at, 'enabled', ev.enabled, 'by',
                            u.handle, 'cancelled', ev.cancelled)
                    ORDER BY ev.at)
                FROM season_map_events ev
                JOIN users u ON u.id = ev.by_user
                WHERE ev.season_map_id = sm.id), '[]'::jsonb)))::json AS body
FROM season_maps sm
JOIN seasons se ON se.id = sm.season_id
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND season_visible(se, session_viewer(($4)::uuid, ($5)::uuid))
AND sm.map_id = ($3)::text
