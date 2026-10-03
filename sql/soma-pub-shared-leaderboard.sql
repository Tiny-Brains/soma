-- SHARED by the public route (no session: $7 and $8 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
WITH season AS (
    SELECT s.id, s.slug, s.name, (s.closed_at IS NOT NULL) AS closed
    FROM games g, viewable_season(g.id, ($6)::text, session_viewer(($7)::uuid, ($8)::uuid)) s
    WHERE g.slug = ($1)::text ),
lim AS (
    SELECT least(greatest(($3)::int, 1), 200) AS n ),
-- A CLOSED SEASON IS READ FROM ITS RECORD (season_standings, the newest revision), written when it
-- closed; nothing below ranks it again. A live season -- or a closed one with no record, which a
-- cutover's backfill leaves none of -- is ranked by ladder_standings(), the code the close renders
-- a record with.
rec AS (
    SELECT r.revision, r.columns FROM season, season_record_latest(season.id) r ),
board AS (
    SELECT st.rank, st.entry
      FROM season, rec, season_standings st
     WHERE st.season_id = season.id AND st.revision = rec.revision AND st.ladder = ($2)::ladder
    UNION ALL
    SELECT l.rank, l.entry
      FROM season, ladder_standings(season.id, ($2)::ladder, ($5)::float8) l
     WHERE NOT EXISTS (SELECT 1 FROM rec) ),
-- THE SEASON'S CURRENT ROUND, if it is played in rounds or in its finals: the header's "Round 3 ·
-- 100 games each". Each row carries its games in it as `round_matches`.
rnd AS (
    SELECT r.n, r.kind, r.games FROM season CROSS JOIN LATERAL season_round(season.id) r
     WHERE r.n IS NOT NULL ),
page AS (
    SELECT b.rank, b.entry FROM board b
     ORDER BY b.rank
    OFFSET ($4)::int
     LIMIT (SELECT n FROM lim) )
SELECT json_build_object(
         'season',      (SELECT slug FROM season),
         'season_name', (SELECT name FROM season),
         'closed',      (SELECT closed FROM season),
         'round',       (SELECT json_build_object('n', n, 'kind', kind, 'games', games) FROM rnd),
         'total',       (SELECT count(*) FROM board),
         'columns',     coalesce((SELECT columns FROM rec), standings_columns(1)),
         'entries',     coalesce(json_agg(page.entry ORDER BY page.rank), '[]'::json),
         'next_cursor', CASE WHEN count(*) = (SELECT n FROM lim)
                             THEN (($4)::int + (SELECT n FROM lim))::text END) AS body,
       EXISTS (SELECT 1 FROM games WHERE slug = ($1)::text) AS found
FROM page
