-- Twelve cards beside one public match, from its own season: six of these models' latest (taken in
-- turns, the winner's model first, then by each model's rank in this match), three more on the same board,
-- then the season's latest. Each group over-fetches so a match already chosen above is skipped and
-- the group still fills; the first group a match appears in keeps it. A model's latest are read
-- backwards off its versions' rating_events (count folds in play order, so seq is play order), and
-- the board and season groups off matches_season_played_idx, each stopping at its LIMIT.
WITH src AS (
    SELECT m.id, m.season_id, m.season_map_id
      FROM matches m
     WHERE m.id = ($1)::uuid AND match_public(m)
), seated AS (
    SELECT v.model_id, min(s.rank) AS best
      FROM src
      JOIN match_seats s     ON s.match_id = src.id
      JOIN model_versions v  ON v.id = s.version_id
     GROUP BY v.model_id
), per_model AS (
    SELECT x.id, sd.best,
           row_number() OVER (PARTITION BY sd.model_id ORDER BY x.played_at DESC, x.id DESC) AS k
      FROM src
      JOIN seated sd          ON true
      JOIN model_versions v   ON v.model_id = sd.model_id AND v.season_id = src.season_id
     CROSS JOIN LATERAL (SELECT mt.id, mt.played_at
                           FROM rating_events ev JOIN matches mt ON mt.id = ev.match_id
                          WHERE ev.version_id = v.id AND ev.ladder = 'open' AND ev.seq > 0
                            AND mt.id <> src.id AND match_counted(mt)
                          ORDER BY ev.seq DESC LIMIT 7) x
), theirs AS (
    -- Interleaved: each model's newest, then each model's second, and so on, the winner's model
    -- first in every round. A match both models played takes its earlier slot.
    SELECT p.id, 1 AS grp,
           row_number() OVER (ORDER BY min(p.k), min(p.best) NULLS LAST, p.id) AS ord
      FROM per_model p
     WHERE p.k <= 6
     GROUP BY p.id
     ORDER BY ord
     LIMIT 18
), board AS (
    SELECT mt.id, 2 AS grp, row_number() OVER (ORDER BY mt.played_at DESC, mt.id DESC) AS ord
      FROM matches mt
     WHERE mt.season_id = (SELECT season_id FROM src) AND mt.season_map_id = (SELECT season_map_id FROM src)
       AND mt.id <> (SELECT id FROM src) AND match_counted(mt)
     ORDER BY mt.played_at DESC, mt.id DESC
     LIMIT 12
), latest AS (
    SELECT mt.id, 3 AS grp, row_number() OVER (ORDER BY mt.played_at DESC, mt.id DESC) AS ord
      FROM matches mt
     WHERE mt.season_id = (SELECT season_id FROM src)
       AND mt.id <> (SELECT id FROM src) AND match_counted(mt)
     ORDER BY mt.played_at DESC, mt.id DESC
     LIMIT 24
), firsts AS (
    SELECT DISTINCT ON (c.id) c.id, c.grp, c.ord
      FROM (SELECT * FROM theirs UNION ALL SELECT * FROM board UNION ALL SELECT * FROM latest) c
     ORDER BY c.id, c.grp, c.ord
), chosen AS (
    SELECT k.id, k.grp, k.ord
      FROM (SELECT f.*, row_number() OVER (PARTITION BY f.grp ORDER BY f.ord) AS n FROM firsts f) k
     WHERE (k.grp = 1 AND k.n <= 6) OR (k.grp = 2 AND k.n <= 3) OR k.grp = 3
     ORDER BY k.grp, k.ord
     LIMIT 12
)
SELECT json_build_object(
        'id', src.id,
        'matches', coalesce((SELECT json_agg(match_summary_json(m) ORDER BY c.grp, c.ord)
                               FROM chosen c JOIN matches m ON m.id = c.id), '[]'::json)) AS body
  FROM src
