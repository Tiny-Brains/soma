-- SHARED by the public route (no session: $3 and $4 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
-- ONE VERSION BY ID, public once it is (version_public) and only in a public season: a private
-- season's version answers 404 here as one that does not exist.
SELECT version_json(v, ($2)::float8) AS body
FROM model_versions v
WHERE v.id = ($1)::uuid
AND version_public(v.status)
AND EXISTS (SELECT 1 FROM seasons s WHERE s.id = v.season_id AND season_visible(s, session_viewer(($3)::uuid, ($4)::uuid)))
