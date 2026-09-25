WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    -- The two sort keys are written here, inside the fence. match_sort_keys() reads `ratings` in
    -- this statement's snapshot, which is before `applied` below moves them: every CTE shares one
    -- snapshot, so the upset is judged on the ratings the match was played between.
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq'),
           (margin, upset) = (SELECT k.margin, k.upset FROM match_sort_keys(m.id) k)
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
       AND m.trial_version_id IS NULL
       AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders)
 RETURNING m.id, m.season_id, m.season_map_id, m.played_at
), board AS (
    -- The counts the maps page and the season object read, moved by the statement that counts the
    -- match, so neither ever counts the season. Count is one clock under a fence, so these rows
    -- are never contended. The board's latest is the newest by (played_at, id), whatever order
    -- the batch folds in.
    UPDATE season_maps sm
       SET matches = sm.matches + 1,
           latest_match_id = CASE WHEN sm.latest_match_id IS NULL
                                    OR (SELECT (l.played_at, l.id) FROM matches l WHERE l.id = sm.latest_match_id)
                                       < (mark.played_at, mark.id)
                                  THEN mark.id ELSE sm.latest_match_id END
      FROM mark
     WHERE sm.id = mark.season_map_id
 RETURNING sm.id
), tally AS (
    UPDATE seasons s
       SET matches_played = s.matches_played + 1
      FROM mark
     WHERE s.id = mark.season_id
 RETURNING s.id
), post AS (
    -- Each seat's result rides with its new rating: first alone is a win, a shared first a draw,
    -- anything else a loss, so the record moves in the same row as matches_played.
    SELECT p.*,
           CASE WHEN ms.rank = 1 AND (SELECT count(*) FROM match_seats f
                                       WHERE f.match_id = mark.id AND f.rank = 1) = 1 THEN 'win'
                WHEN ms.rank = 1 THEN 'draw'
                ELSE 'loss' END AS result
      FROM mark
     CROSS JOIN LATERAL jsonb_to_recordset(($4)::jsonb)
             -- `model_id` is the plugin's own output key and is a VERSION id; the column below
             -- is named for the wire and joined to ratings.version_id.
             AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8)
      JOIN match_seats ms ON ms.match_id = mark.id AND ms.seat = p.seat
), applied AS (
    UPDATE ratings r
       SET mu = post.mu, sigma = post.sigma,
           matches_played = r.matches_played + 1, updated_at = now(),
           wins   = r.wins   + (post.result = 'win')::int,
           draws  = r.draws  + (post.result = 'draw')::int,
           losses = r.losses + (post.result = 'loss')::int
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
