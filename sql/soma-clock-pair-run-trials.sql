WITH cand AS (
    SELECT c.id, c.game_id, c.season_id, c.model_id, c.weight_class, e.owner_id, s.rules,
           (SELECT count(*) FROM matches x WHERE x.trial_version_id = c.id
               AND x.fault_reason IS DISTINCT FROM 'MODEL_UNAVAILABLE') AS trials,
           (SELECT count(*) FROM matches x WHERE x.trial_version_id = c.id
               AND x.fault_reason = 'MODEL_UNAVAILABLE') AS refused
      FROM model_versions c
      JOIN models e  ON e.id = c.model_id
      JOIN seasons s ON s.id = c.season_id
     WHERE c.game_id = ($1)::uuid AND c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running', 'finished'))
), pick AS (
    SELECT cand.*, p.id AS map, p.players
      FROM cand
      JOIN LATERAL (
          -- The season's enabled boards in the order they were added, narrowed to the ones this
          -- season's baselines can seat: the candidate, and one baseline of a different owner in
          -- every other seat, exactly as `seated` below draws them. The candidate's `trials`
          -- rotates over them, so a re-pair changes the board.
          SELECT b.id, b.players
            FROM (SELECT sm.id, sm.players,
                         row_number() OVER (ORDER BY sm.added_at, sm.map_id) - 1 AS k,
                         count(*) OVER () AS n
                    FROM season_maps sm
                   WHERE sm.season_id = cand.season_id AND sm.enabled
                     AND sm.players <= 1 + (
                         SELECT count(DISTINCT be.owner_id)
                           FROM model_versions bv
                           JOIN models be ON be.id = bv.model_id
                           JOIN users ub  ON ub.id = be.owner_id AND ub.role = 'baseline'
                          WHERE bv.game_id = cand.game_id AND bv.season_id = cand.season_id
                            AND bv.status = 'active')) b
           WHERE b.k = cand.trials % b.n
      ) p ON true
     WHERE cand.trials < coalesce((cand.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int)
       AND cand.refused < coalesce((cand.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int)
), seated AS (
    SELECT pick.id AS trial_version_id, pick.map, pick.players,
           jsonb_build_array(pick.id) || coalesce(opp.ids, '[]'::jsonb) AS seats
      FROM pick
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(b.id ORDER BY b.rn) AS ids
            FROM (SELECT DISTINCT ON (be.owner_id) b.id, be.owner_id,
                         row_number() OVER (
                             ORDER BY (b.weight_class = pick.weight_class) DESC,
                                      (SELECT count(*) FROM match_seats s
                                         JOIN matches m ON m.id = s.match_id
                                        WHERE s.version_id = b.id
                                          AND m.status IN ('pending', 'claimed', 'running')),
                                      b.id) AS rn
                    FROM model_versions b
                    JOIN models be ON be.id = b.model_id
                    JOIN users ub  ON ub.id = be.owner_id AND ub.role = 'baseline'
                   WHERE b.game_id = pick.game_id AND b.season_id = pick.season_id
                     AND b.status = 'active'
                     -- ONE SEAT PER OWNER among the opponents, and this is not cosmetic: a season
                     -- forbidding self-pairing makes P_INSERT refuse a match seating two versions
                     -- of one owner, and a trial is plan item 0. A trial the insert refuses halts
                     -- the whole run, every run, for ever -- so trials must never propose one.
                   ORDER BY be.owner_id, b.id) b
           WHERE b.rn < pick.players
      ) opp ON true
)
SELECT json_build_object('n', count(*), 'pairings', coalesce(json_agg(json_build_object(
         'seats', seats, 'trial', trial_version_id, 'map', map,
         'seed', (random() * 2147483647)::bigint)), '[]'::json)) AS body
  FROM seated
 WHERE jsonb_array_length(seats) = players
