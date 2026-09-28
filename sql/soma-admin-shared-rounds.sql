-- A SEASON'S ROUNDS, FINALS AND FILL, AS AN ADMIN DRIVES THEM: everything the admin's rounds page
-- reads, and what every write on it answers with. The season's state and closure policy; the idle
-- fill as set; every round, newest first, with the current one marked; the finals' standing
-- (season_finals); each active version's games in the current round and in flight, least-played
-- first, which is the finals' progress table; how many submissions are still being admitted (the
-- finals wait for none); and the capacity the numbers are chosen against -- the lanes of the live
-- runners that may play this season, what they hold and what is queued on the engine, and the
-- season's last hour, from which `per_hour` is the lanes' matches an hour at its median length.
WITH s AS (
    SELECT se.*
      FROM seasons se JOIN games g ON g.id = se.game_id
     WHERE g.slug = ($1)::text AND se.slug = ($2)::text
), cur AS (
    SELECT r.n, r.kind, r.games FROM s CROSS JOIN LATERAL season_round(s.id) r WHERE r.n IS NOT NULL
), games_now AS (
    SELECT g.version_id, g.games FROM s, cur, round_games(s.id, cur.n) g
), flight AS (
    SELECT st.version_id, count(*) AS n
      FROM s JOIN matches m ON m.season_id = s.id
      JOIN match_seats st ON st.match_id = m.id
     WHERE m.status IN ('pending', 'claimed', 'running', 'finished') AND m.trial_version_id IS NULL
     GROUP BY st.version_id
), lanes AS (
    SELECT coalesce(sum(lr.max_in_flight), 0) AS n, count(*) AS runners
      FROM s
      JOIN live_runners lr ON true
      JOIN runners r ON r.id = lr.id
     WHERE r.plays_matches
       AND r.engine_digest = s.engine_digest
       AND r.last_seen_at > now() - interval '90 seconds'
       AND CASE WHEN lr.season_id IS NOT NULL
                THEN lr.season_id = s.id AND (s.fleet ->> 'matches') IN ('own', 'both')
                ELSE (s.fleet ->> 'matches') IN ('platform', 'both') END
), hour AS (
    SELECT count(*) AS played, percentile_disc(0.5) WITHIN GROUP (ORDER BY m.played_ms) AS median_ms
      FROM s JOIN matches m ON m.season_id = s.id
     WHERE m.played_at > now() - interval '1 hour' AND m.trial_version_id IS NULL
)
SELECT json_build_object(
         'season',        s.slug,
         'name',          s.name,
         'state',         season_state(s),
         'submissions_close_at', s.submissions_close_at,
         'close_requested_at',   s.close_requested_at,
         'policy',        coalesce(s.rules -> 'closure' ->> 'policy', 'settle'),
         'rules',         s.rules -> 'rounds',
         'fill',          s.fill,
         -- The fleet policy beside the fill: both are capacity a platform admin changes while live.
         'fleet',         s.fleet,
         'current',       (SELECT n FROM cur),
         'rounds',        (SELECT coalesce(json_agg(json_build_object(
                              'n', r.n, 'kind', r.kind, 'starts_at', r.starts_at, 'games', r.games,
                              'sigma_floor', r.sigma_floor, 'mu_shrink', r.mu_shrink,
                              'warn_minutes', r.warn_minutes, 'announced_at', r.announced_at,
                              'applied_at', r.applied_at, 'cancelled_at', r.cancelled_at,
                              'by', u.handle, 'current', r.n = (SELECT n FROM cur))
                              ORDER BY r.n DESC), '[]'::json)
                             FROM season_rounds r LEFT JOIN users u ON u.id = r.created_by
                            WHERE r.season_id = s.id),
         'finals',        (SELECT json_build_object('n', f.n, 'games', f.games, 'starts_at', f.starts_at,
                                                    'started', f.applied, 'entries', f.entries,
                                                    'complete', f.complete, 'done', f.done)
                             FROM season_finals(s.id) f),
         'versions',      (SELECT coalesce(json_agg(json_build_object(
                              'version_id', v.id, 'model', e.name, 'owner', u.handle,
                              'class', v.weight_class, 'baseline', u.role = 'baseline',
                              'games', coalesce(gn.games, 0), 'in_flight', coalesce(fl.n, 0),
                              'season_games', coalesce(r.matches_played, 0),
                              'rating', r.conservative, 'sigma', r.sigma)
                              ORDER BY u.role = 'baseline', coalesce(gn.games, 0), r.conservative DESC NULLS LAST),
                              '[]'::json)
                             FROM model_versions v
                             JOIN models e ON e.id = v.model_id
                             JOIN users u  ON u.id = e.owner_id
                             LEFT JOIN ratings r   ON r.version_id = v.id AND r.ladder = 'open'
                             LEFT JOIN games_now gn ON gn.version_id = v.id
                             LEFT JOIN flight fl    ON fl.version_id = v.id
                            WHERE v.season_id = s.id AND v.status = 'active'),
         'admitting',     (SELECT count(*) FROM model_versions v
                            WHERE v.season_id = s.id AND v.status IN ('testing', 'verified')),
         'capacity',      (SELECT json_build_object(
                              'runners', lanes.runners, 'lanes', lanes.n,
                              'playing', (SELECT count(*) FROM matches m
                                           WHERE m.engine_digest = s.engine_digest
                                             AND m.status IN ('claimed', 'running')),
                              'queued',  (SELECT count(*) FROM matches m
                                           WHERE m.engine_digest = s.engine_digest
                                             AND m.status = 'pending'),
                              'played_last_hour', hour.played,
                              'median_ms', hour.median_ms,
                              'per_hour', CASE WHEN hour.median_ms > 0
                                               THEN floor(lanes.n * 3600000.0 / hour.median_ms)::int END)
                             FROM lanes, hour)
       ) AS body
  FROM s
