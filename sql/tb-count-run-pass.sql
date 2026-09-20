WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), live AS (
    -- The candidate's season must be live, and the guard sits on the mark because a
    -- data-modifying CTE runs whether or not the outer statement uses it. Never reached in
    -- practice -- a close rejects a waiting candidate in the same statement -- but never is a
    -- promise, and this is a predicate.
    SELECT s.id,
           coalesce((s.rules -> 'rating' ->> 'prior_mu')::float8,        ($5)::float8) AS prior_mu,
           coalesce((s.rules -> 'rating' ->> 'prior_sigma')::float8,     ($6)::float8) AS prior_sigma,
           coalesce((s.rules -> 'rating' ->> 'sigma_inflation')::float8, ($7)::float8) AS inflation
      FROM seasons s JOIN model_versions c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), pred AS (
    -- The version this one replaces: THE SAME ENTRY'S, in the same season. Scoped by owner, as it
    -- was before the entry split, promoting one of a competitor's models would supersede all of
    -- the others -- their whole portfolio killed by one successful trial.
    UPDATE model_versions p SET status = 'superseded'
      FROM bump, model_versions cand
     WHERE cand.id = ($4)::uuid
       AND p.model_id = cand.model_id
       AND p.season_id = cand.season_id AND p.status = 'active'        -- within the season
 RETURNING p.id
), cand AS (
    UPDATE model_versions c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
       AND (SELECT count(*) FROM pred) >= 0
 RETURNING c.id, c.weight_class
), seeded AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, live.prior_mu),
           coalesce(seed.sigma, live.prior_sigma),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN live
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.version_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * live.inflation, live.prior_sigma) END AS sigma
      ) seed
 RETURNING version_id, ladder, mu, sigma
)
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT version_id, ladder, 0, mu, sigma FROM seeded
