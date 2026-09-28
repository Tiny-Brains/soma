-- Why an edit wrote nothing, in the order the workflow refuses: no such season or round (404), the
-- season or the round is over -- closed, or cancelled (409), a started round asked to change more
-- than its games or to cancel (409), an empty edit, a start in the past or numbers out of range (422).
SELECT json_build_object(
         'found',     x.n IS NOT NULL,
         'closed',    s.closed_at IS NOT NULL,
         'cancelled', x.cancelled_at IS NOT NULL,
         'started',   x.applied_at IS NOT NULL
                      AND (($4)::timestamptz IS NOT NULL OR ($6)::float8 IS NOT NULL
                        OR ($7)::float8 IS NOT NULL OR ($8)::float8 IS NOT NULL
                        OR coalesce(($9)::boolean, false)),
         'valid',     season_round_numbers_ok(($5)::float8, ($6)::float8, ($7)::float8, ($8)::float8)
                      AND NOT (($4)::timestamptz IS NOT NULL AND ($4)::timestamptz <= now() - interval '1 minute')
                      AND (($4)::timestamptz IS NOT NULL OR ($5)::float8 IS NOT NULL
                        OR ($6)::float8 IS NOT NULL OR ($7)::float8 IS NOT NULL
                        OR ($8)::float8 IS NOT NULL OR coalesce(($9)::boolean, false))
       ) AS body
  FROM games g
  LEFT JOIN seasons s       ON s.game_id = g.id AND s.slug = ($2)::text
  LEFT JOIN season_rounds x ON x.season_id = s.id AND x.n = ($3)::int
 WHERE g.slug = ($1)::text
