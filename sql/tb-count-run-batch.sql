WITH folds AS (
    SELECT json_build_object('kind', 'fold', 'id', m.id) AS item, 0 AS grp, m.played_at AS ord, m.id
      FROM matches m
     WHERE m.status = 'finished' AND m.trial_version_id IS NULL
     ORDER BY m.played_at, m.id
     LIMIT ($1)::int
), verdicts AS (
    SELECT json_build_object(
             'kind', 'verdict', 'model_id', c.id, 'trial_id', t.id,
             -- THE VERSION THIS ONE WOULD REPLACE: the entry's own active version, in the
             -- candidate's own season. Both terms are load-bearing. Entry-scoped, because an owner
             -- now holds one active version PER ENTRY; season-scoped, because they also hold one in
             -- every season they ever finished -- a closed season's active version IS its standing.
             -- Scoped by owner alone, as this read was before the entry split, the scalar subquery
             -- raises "more than one row" the first time a second season opens, and the count clock
             -- dies with the whole ladder behind it.
             'predecessor_id', (SELECT p.id FROM model_versions p
                                 WHERE p.model_id = c.model_id AND p.season_id = c.season_id
                                   AND p.status = 'active'),
             'trials', n.trials,
             -- The strike ceiling is READ OFF THE TRIAL ROW, not off this package's config. It is
             -- the number the wave actually played by, so count now judges a trial by the rule that
             -- was applied to it by construction, rather than because two [vars] in two repositories
             -- were asserted equal.
             -- A REFUSED TRIAL (MODEL_UNAVAILABLE: no runner could serve a seat's model within the
             -- gate's grace) was never played, so it is not the candidate's attempt: `trials`
             -- leaves it out and `refused` counts it against a ceiling of its own, whose reason
             -- names the fleet rather than the model.
             'decision', CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN 'pass'
                              WHEN t.status = 'finished'                           THEN 'reject'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'reject'
                              WHEN n.trials >= tm.trials_max                        THEN 'reject'
                              WHEN n.refused >= tm.trials_max                       THEN 'reject'
                              ELSE 'repair' END,
             'reason',   CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN NULL
                              WHEN t.status = 'finished'                           THEN 'FORFEIT'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'FAULT:' || t.fault_reason
                              WHEN n.trials >= tm.trials_max                        THEN 'UNPLAYABLE'
                              WHEN n.refused >= tm.trials_max                       THEN 'RUNNER_UNAVAILABLE'
                              ELSE NULL END) AS item,
           1 AS grp, t.played_at AS ord, c.id
      FROM model_versions c
      JOIN seasons cse ON cse.id = c.season_id
      CROSS JOIN LATERAL (SELECT coalesce((cse.rules -> 'pairing' ->> 'trials_max')::int,
                                          ($2)::int) AS trials_max) tm
      JOIN LATERAL (SELECT t.* FROM matches t
                     WHERE t.trial_version_id = c.id
                       AND t.status IN ('finished', 'failed', 'cancelled')
                     ORDER BY t.created_at DESC LIMIT 1) t ON true
      JOIN match_seats cs ON cs.match_id = t.id AND cs.version_id = c.id
      JOIN LATERAL (SELECT count(*) FILTER (WHERE x.fault_reason IS DISTINCT FROM 'MODEL_UNAVAILABLE') AS trials,
                           count(*) FILTER (WHERE x.fault_reason = 'MODEL_UNAVAILABLE') AS refused
                      FROM matches x WHERE x.trial_version_id = c.id) n ON true
     WHERE c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running'))
)
SELECT json_build_object('n', count(*),
         'items', coalesce(json_agg(item ORDER BY grp, ord, id), '[]'::json)) AS body
  FROM (SELECT * FROM folds UNION ALL SELECT * FROM verdicts) x
