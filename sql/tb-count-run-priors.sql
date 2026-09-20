SELECT json_build_object(
         -- The keys `trial_model_id` and `model_id` are the plugin's WIRE FORMAT and stay as they
         -- are though the columns behind them are now named for versions. Renaming a column is a
         -- schema change; renaming these would be a change to tb.rating.trueskill and its tests.
         'id', m.id, 'trial_model_id', m.trial_version_id, 'ladders', m.ladders,
         'seat_count', m.seat_count,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.version_id, 'rank', s.rank, 'strikes', s.strikes,
                      'ratings', (SELECT json_agg(json_build_object(
                                            'ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                                          ORDER BY r.ladder)
                                    FROM ratings r
                                   WHERE r.version_id = s.version_id AND r.ladder = ANY (m.ladders)))
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row,
       -- TrueSkill's parameters, read from THE SEASON THIS MATCH BELONGS TO rather than from
       -- [vars]. Bound to the match being folded and not to the run, which is what makes a batch
       -- spanning a season boundary impossible to fold with mixed constants -- there is no
       -- run-scoped copy for the second season's matches to inherit.
       coalesce((se.rules -> 'rating' ->> 'beta')::float8,             ($2)::float8) AS beta,
       coalesce((se.rules -> 'rating' ->> 'tau')::float8,              ($3)::float8) AS tau,
       coalesce((se.rules -> 'rating' ->> 'draw_probability')::float8, ($4)::float8) AS draw_probability
  FROM matches m
  JOIN seasons se ON se.id = m.season_id
 WHERE m.id = ($1)::uuid AND m.status = 'finished'
