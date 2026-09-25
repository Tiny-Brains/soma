-- The card's resting picture: the runner's last frame, as sent, and what each seat scored. Public
-- matches only (match_public). No board -- the browser holds it from the maps route.
SELECT json_build_object(
        'id',    m.id,
        'map',   sm.map_id,
        'turn',  f.turn,
        'seats', (SELECT coalesce(json_agg(json_build_object(
                     'seat', s.seat, 'model_id', s.model_id, 'model', s.model_name, 'owner', s.owner,
                     'version', s.version, 'rank', s.rank, 'score', s.score, 'outcome', s.outcome)
                     ORDER BY s.seat), '[]'::json)
                    FROM match_seat_rows(m.id) s),
        'frame', f.frame) AS body,
       f.match_id IS NOT NULL AS has_frame
  FROM matches m
  JOIN season_maps sm ON sm.id = m.season_map_id
  LEFT JOIN match_frames f ON f.match_id = m.id
 WHERE m.id = ($1)::uuid
   AND match_public(m)
