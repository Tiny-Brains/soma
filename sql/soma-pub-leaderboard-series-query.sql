-- The bucketed series for one ladder of a season (rating_series, which reads ladder_snapshots for
-- every edge but the last). `ladder` defaults to open, `since` to the season's opening; `points`
-- is clamped there.
SELECT json_build_object(
        'season', s.slug,
        'ladder', coalesce(($2)::ladder, 'open'),
        'series', rating_series(s.id, coalesce(($2)::ladder, 'open'), coalesce(($3)::timestamptz, s.submissions_open_at),
                                coalesce(($4)::int, 60))) AS body
  FROM games g, public_season(g.id, ($5)::text) s
 WHERE g.slug = ($1)::text
