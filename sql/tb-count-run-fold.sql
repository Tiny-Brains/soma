WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
       AND m.trial_version_id IS NULL
       AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders)
 RETURNING m.id
), post AS (
    SELECT p.*
      FROM mark,
           jsonb_to_recordset(($4)::jsonb)
             -- `model_id` is the plugin's own output key and is a VERSION id; the column below
             -- is named for the wire and joined to ratings.version_id.
             AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8)
), applied AS (
    UPDATE ratings r
       SET mu = post.mu, sigma = post.sigma,
           matches_played = r.matches_played + 1, updated_at = now()
      FROM post, ratings old
     WHERE r.version_id = post.model_id AND r.ladder = post.ladder::ladder
       AND old.version_id = r.version_id AND old.ladder = r.ladder
 RETURNING r.version_id, r.ladder, r.matches_played AS seq, post.seat,
           old.mu AS mu_before, old.sigma AS sigma_before, r.mu AS mu_after, r.sigma AS sigma_after
)
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat,
                           mu_before, sigma_before, mu_after, sigma_after)
SELECT a.version_id, a.ladder, a.seq, mark.id, a.seat,
       a.mu_before, a.sigma_before, a.mu_after, a.sigma_after
  FROM applied a, mark
