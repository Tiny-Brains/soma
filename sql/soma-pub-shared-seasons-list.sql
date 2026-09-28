-- SHARED by the public route (no session: $2 and $3 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
SELECT EXISTS (SELECT 1 FROM games WHERE slug = ($1)::text) AS found, coalesce((SELECT json_agg(season_json(s) ORDER BY s.number DESC) FROM seasons s JOIN games g ON g.id = s.game_id WHERE g.slug = ($1)::text AND season_visible(s, session_viewer(($2)::uuid, ($3)::uuid))), '[]'::json) AS body
