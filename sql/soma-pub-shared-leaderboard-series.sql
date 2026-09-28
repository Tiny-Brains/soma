-- SHARED by the public route (no session: $6 and $7 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
-- The bucketed series for one ladder of a season (rating_series, which reads ladder_snapshots for
-- every edge but the last). `ladder` defaults to open, `since` to the season's opening; `points`
-- is clamped there.
SELECT json_build_object(
        'season', s.slug,
        'ladder', coalesce(($2)::ladder, 'open'),
        'series', rating_series(s.id, coalesce(($2)::ladder, 'open'), coalesce(($3)::timestamptz, s.submissions_open_at),
                                coalesce(($4)::int, 60))) AS body
  FROM games g, viewable_season(g.id, ($5)::text, session_viewer(($6)::uuid, ($7)::uuid)) s
 WHERE g.slug = ($1)::text
