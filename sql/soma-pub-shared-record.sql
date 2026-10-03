-- SHARED by the public route (no session: $3 and $4 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
-- A closed season's whole record as one document (season_record_document): what an archive keeps
-- for ever. `record` is null for a live season, which has none yet.
SELECT json_build_object(
         'season',      s.slug,
         'season_name', s.name,
         'closed',      s.closed_at IS NOT NULL,
         'record',      season_record_document(s.id)) AS body
  FROM seasons s JOIN games g ON g.id = s.game_id
 WHERE g.slug = ($1)::text AND s.slug = ($2)::text
   AND season_visible(s, session_viewer(($3)::uuid, ($4)::uuid))
