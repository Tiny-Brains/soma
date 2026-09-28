-- SHARED by the public route (no session: $2 and $3 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
-- ONE MATCH BY ID, for anyone who may see its season. A trial is readable only once public
-- (match_public: its candidate passed). An ordinary match is readable in any state -- a cancelled or
-- failed one too -- but ONLY in a public season: a private season's match answers 404 here exactly
-- as one that does not exist, and its members read it through their own route.
SELECT mt.replay_key, match_detail_json(mt) AS body
FROM matches mt
WHERE mt.id = ($1)::uuid
AND CASE WHEN mt.trial_version_id IS NOT NULL THEN match_visible(mt, session_viewer(($2)::uuid, ($3)::uuid))
         ELSE EXISTS (SELECT 1 FROM seasons s WHERE s.id = mt.season_id AND season_visible(s, session_viewer(($2)::uuid, ($3)::uuid)))
    END
