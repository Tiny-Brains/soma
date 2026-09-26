-- ON A BOARD RIGHT NOW: claimed or running, trials excluded, like matches_played. Its own route,
-- uncached, because it moves at every claim, finish and release and would otherwise invalidate the
-- season document, and every cached route that carries it, that often.
SELECT json_build_object('playing', (SELECT count(*) FROM matches mt
                                      WHERE mt.season_id = s.id AND mt.status IN ('claimed', 'running')
                                        AND mt.trial_version_id IS NULL)) AS body
  FROM seasons s
  JOIN games g ON g.id = s.game_id
 WHERE g.slug = ($1)::text AND s.slug = ($2)::text
