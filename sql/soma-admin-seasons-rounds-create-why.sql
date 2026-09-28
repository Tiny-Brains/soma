-- Why a schedule wrote nothing, in the order the workflow refuses: no such season (404), closed
-- (409), a round already waiting (409), the finals already scheduled (409), finals before the window
-- closed or with submissions still being admitted (409), a start in the past or numbers out of
-- range (422).
SELECT json_build_object(
         'found',     s.id IS NOT NULL,
         'closed',    s.closed_at IS NOT NULL,
         'waiting',   EXISTS (SELECT 1 FROM season_rounds w
                               WHERE w.season_id = s.id AND w.applied_at IS NULL AND w.cancelled_at IS NULL),
         'finals',    EXISTS (SELECT 1 FROM season_rounds f
                               WHERE f.season_id = s.id AND f.kind = 'finals' AND f.cancelled_at IS NULL),
         'window_open', s.submissions_close_at > now(),
         'admitting', (SELECT count(*) FROM model_versions v
                        WHERE v.season_id = s.id AND v.status IN ('testing', 'verified')),
         'past',      ($4)::timestamptz IS NOT NULL AND ($4)::timestamptz <= now() - interval '1 minute',
         'valid',     ($3)::text IN ('round', 'finals') AND ($5)::float8 IS NOT NULL
                      AND season_round_numbers_ok(($5)::float8, ($6)::float8, ($7)::float8, ($8)::float8)
       ) AS body
  FROM games g
  LEFT JOIN seasons s ON s.game_id = g.id AND s.slug = ($2)::text
 WHERE g.slug = ($1)::text
