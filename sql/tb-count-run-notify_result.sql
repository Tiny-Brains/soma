WITH m AS (
    SELECT mt.id, mt.seat_count, sm.map_id, g.slug AS game, se.slug AS season
      FROM matches mt
      JOIN games g        ON g.id = mt.game_id
      JOIN seasons se     ON se.id = mt.season_id
      JOIN season_maps sm ON sm.id = mt.season_map_id
     WHERE mt.id = ($1)::uuid AND mt.status = 'rated' AND mt.trial_version_id IS NULL
), seats AS MATERIALIZED (
    SELECT r.* FROM m CROSS JOIN LATERAL match_seat_rows(m.id) r
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, match_id, actor, data, dedupe_key)
SELECT s.owner_id, 'matches', 'result',
       CASE WHEN s.outcome = 'dq'  THEN 'bad'
            WHEN s.strikes > 0     THEN 'warn'
            WHEN s.outcome = 'win' THEN 'ok'
            ELSE                        'info' END,
       s.model_name || ' v' || s.version ||
         CASE WHEN s.outcome = 'dq'                         THEN ' was disqualified'
              WHEN m.seat_count = 2 AND s.outcome = 'win'   THEN ' won'
              WHEN m.seat_count = 2 AND s.outcome = 'draw'  THEN ' drew'
              WHEN m.seat_count = 2                         THEN ' lost'
              ELSE ' placed ' || (s.rank)::text || CASE WHEN (s.rank) % 100 IN (11, 12, 13) THEN 'th' WHEN (s.rank) % 10 = 1 THEN 'st' WHEN (s.rank) % 10 = 2 THEN 'nd' WHEN (s.rank) % 10 = 3 THEN 'rd' ELSE 'th' END || ' of ' || m.seat_count END,
       'Scored ' || s.score || ' on ' || m.map_id ||
         CASE WHEN s.strikes = 1 THEN ', with 1 strike'
              WHEN s.strikes > 1 THEN ', with ' || s.strikes || ' strikes'
              ELSE '' END || '.',
       '/matches/' || m.id,
       m.game, m.season, s.model_id, s.version_id, m.id,
       (SELECT o.owner FROM seats o WHERE o.seat <> s.seat ORDER BY o.rank NULLS LAST, o.seat LIMIT 1),
       jsonb_strip_nulls(jsonb_build_object(
           'place', s.rank, 'of', m.seat_count, 'score', s.score, 'strikes', s.strikes,
           'outcome', s.outcome, 'class', s.class, 'map', m.map_id,
           -- the change in the CONSERVATIVE rating on open, which is the number a ladder prints
           'delta', (SELECT round(((ev.mu_after - 3 * ev.sigma_after)
                                   - (ev.mu_before - 3 * ev.sigma_before))::numeric, 2)
                       FROM rating_events ev
                      WHERE ev.match_id = m.id AND ev.seat = s.seat AND ev.ladder = 'open'),
           'rating', (SELECT round((ev.mu_after - 3 * ev.sigma_after)::numeric, 2)
                        FROM rating_events ev
                       WHERE ev.match_id = m.id AND ev.seat = s.seat AND ev.ladder = 'open'))),
       'result:' || m.id || ':' || s.seat
  FROM m CROSS JOIN seats s
 WHERE s.owner_id IS NOT NULL AND s.rank IS NOT NULL
   AND notification_wanted(s.owner_id, 'matches', s.rank = 1 OR s.strikes > 0)
ON CONFLICT (user_id, dedupe_key) DO NOTHING
