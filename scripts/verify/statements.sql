-- The statements this harness owns, and NOTHING ELSE.
--
-- Every statement that SHIPS is read straight out of the workflow that ships it -- run.sh emits a
-- PREPARE for each before this file is fed to psql -- so there are no copies here to drift from
-- what runs. What is left is the four variants and reads nothing ships, which exist only to prove
-- something about the schema:
--
--   c_pass_reversed  the promotion with its two updates in the opposite order, which the deferred
--                    one-active rule must still commit
--   a_chain          the audit of the rating chain
--   d_demand         the demand view on its own, the shape scripts/autoscaler.sql reads
--   s_history        a version's rating history
--   s_match_change   a match's rating movements
--
-- Add one here only when nothing ships it. If it ships, list it in run.sh's PAIRS instead.

-- The same promotion with the candidate activated BEFORE the predecessor is demoted.
-- Commits only because the one-active rule is deferred to commit.
PREPARE c_pass_reversed (timestamptz, int, uuid, uuid, float8, float8, float8) AS
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), live AS (
    -- The candidate's season must be live, and the guard sits on the mark because a
    -- data-modifying CTE runs whether or not the outer statement uses it. Never reached in
    -- practice -- a close rejects a waiting candidate in the same statement -- but never is a
    -- promise, and this is a predicate.
    SELECT s.id
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
), cand AS (
    UPDATE model_versions c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
 RETURNING c.id, c.weight_class, c.model_id, c.game_id, c.season_id
), pred AS (
    UPDATE model_versions p SET status = 'superseded'
      FROM bump, cand
     WHERE p.model_id = cand.model_id
       AND p.season_id = cand.season_id
       AND p.status = 'active' AND p.id <> cand.id
 RETURNING p.id
), seeded AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, ($5)::float8),
           coalesce(seed.sigma, ($6)::float8),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.version_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * ($7)::float8, ($6)::float8) END AS sigma
      ) seed
 RETURNING version_id, ladder, mu, sigma
)
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT version_id, ladder, 0, mu, sigma FROM seeded;


-- Soma's history read under the two-table shape: a plain join, no containment.
PREPARE s_history (uuid, int) AS
SELECT coalesce(json_agg(x ORDER BY x.played_at DESC), '[]'::json) AS body
  FROM (SELECT mt.id, g.slug AS game, mt.status, mt.reason, mt.played_at
          FROM match_seats s
          JOIN matches mt ON mt.id = s.match_id
          JOIN games g ON g.id = mt.game_id
         WHERE s.version_id = ($1)::uuid AND mt.status IN ('finished', 'rated')
         ORDER BY mt.played_at DESC LIMIT ($2)::int) x;

-- Soma's per-match rating change: the events a match produced, by seat and ladder.
PREPARE s_match_change (uuid) AS
SELECT seat, ladder, mu_before, sigma_before, mu_after, sigma_after
  FROM rating_events WHERE match_id = ($1)::uuid ORDER BY seat, ladder;

-- the chain audit: every event starts where the previous one on its ladder ended.
PREPARE a_chain AS
SELECT e.version_id, e.ladder, e.seq
  FROM rating_events e
  JOIN rating_events p ON p.version_id = e.version_id AND p.ladder = e.ladder AND p.seq = e.seq - 1
 WHERE e.mu_before IS DISTINCT FROM p.mu_after OR e.sigma_before IS DISTINCT FROM p.sigma_after;


-- ---------------------------------------------------------------- the clocks' reads
-- the demand view: state, cap and want per version
PREPARE d_demand (uuid, int, int, float8) AS
WITH live AS (
    SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), v AS (
    SELECT md.id AS model_id, md.weight_class,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM model_versions md
      JOIN live   ON live.id = md.season_id
      LEFT JOIN ratings r ON r.version_id = md.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM model_versions o
           WHERE o.season_id = md.season_id AND o.status = 'active'
             AND o.weight_class = md.weight_class AND o.id <> md.id
      ) reach ON true
     WHERE md.status = 'active'
     GROUP BY md.id, md.weight_class
), f AS (
    SELECT s.version_id AS model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.version_id
), w AS (
    SELECT v.model_id, v.weight_class, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.played < ($2)::int         THEN 'placement'
                WHEN v.sigma  > ($4)::float8      THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.played < ($2)::int         THEN ($2)::int
                WHEN v.sigma  > ($4)::float8      THEN ($3)::int
                ELSE                                   0 END AS cap
      FROM v LEFT JOIN f ON f.model_id = v.model_id
)
SELECT model_id, weight_class, state, sigma, played, in_flight,
       greatest(cap - in_flight, 0) AS want
  FROM w
 ORDER BY want DESC, sigma DESC, model_id;
