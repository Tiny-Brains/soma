-- START EVERY ROUND THAT IS DUE, under count's fence: count is the only writer of a ladder, and a
-- round's reset is a ladder write. One waiting round a season (season_rounds_one_waiting_uniq), so
-- this is at most one row a live season.
--
-- THE RESET is two numbers the round carries. `sigma_floor` raises every active version's Open
-- sigma to at least that, so an old version and a new one carry the same 3-sigma discount and the
-- leaderboard reads them by mu; `mu_shrink` draws each mu that fraction of the way to the season's
-- mean (0 keeps it, 1 is a full reset). Matches, wins and the rating_events history are untouched:
-- `matches_played` is the events' seq, and a reset is not a match. The next event of each version
-- starts from the reset rating, which is how the history shows it.
--
-- THE QUEUE PAIRED FOR THE ROUND BEFORE is cancelled: it would count for a round that has ended.
-- What is already claimed plays on and folds into the reset rating, counted for its own round.
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), due AS (
    SELECT r.season_id, r.n, r.sigma_floor, r.mu_shrink
      FROM season_rounds r
      JOIN seasons s ON s.id = r.season_id AND s.closed_at IS NULL
      JOIN fence ON true
     WHERE r.applied_at IS NULL AND r.cancelled_at IS NULL AND r.starts_at <= now()
       FOR UPDATE OF r
), mean AS (
    SELECT due.season_id, avg(x.mu) AS mu
      FROM due
      JOIN model_versions v ON v.season_id = due.season_id AND v.status = 'active'
      JOIN ratings x        ON x.version_id = v.id AND x.ladder = 'open'
     GROUP BY due.season_id
), reset AS (
    UPDATE ratings x
       SET mu         = x.mu - due.mu_shrink * (x.mu - mean.mu),
           sigma      = greatest(x.sigma, coalesce(due.sigma_floor, 0)),
           updated_at = now()
      FROM model_versions v, due, mean
     WHERE x.version_id = v.id AND x.ladder = 'open'
       AND v.season_id = due.season_id AND v.status = 'active'
       AND mean.season_id = due.season_id
       AND (due.mu_shrink > 0 OR x.sigma < coalesce(due.sigma_floor, 0))
 RETURNING x.version_id
), dropped AS (
    UPDATE matches m
       SET status = 'cancelled', withdrawn_reason = 'ROUND_ENDED', closed_at = now()
      FROM due
     WHERE m.season_id = due.season_id AND m.status = 'pending' AND m.trial_version_id IS NULL
 RETURNING m.id
)
UPDATE season_rounds r
   SET applied_at = now()
  FROM due
 WHERE r.season_id = due.season_id AND r.n = due.n
