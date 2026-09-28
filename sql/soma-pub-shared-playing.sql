-- SHARED by the public route (no session: $3 and $4 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
-- ON A BOARD RIGHT NOW: claimed or running, trials excluded, like matches_played. Its own route,
-- uncached, because it moves at every claim, finish and release and would otherwise invalidate the
-- season document, and every cached route that carries it, that often. A private season answers
-- nothing, as one that does not exist: a count is how a stranger would learn that its slug is real.
SELECT json_build_object('playing', (SELECT count(*) FROM matches mt
                                      WHERE mt.season_id = s.id AND mt.status IN ('claimed', 'running')
                                        AND mt.trial_version_id IS NULL)) AS body
  FROM seasons s
  JOIN games g ON g.id = s.game_id
 WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND season_visible(s, session_viewer(($3)::uuid, ($4)::uuid))
