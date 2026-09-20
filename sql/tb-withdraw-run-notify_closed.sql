WITH closed AS (
    SELECT s.id, s.slug AS season, s.name AS season_name, g.slug
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NOT NULL
     ORDER BY s.closed_at DESC
     LIMIT 1
), standing AS (
    SELECT f.owner_id, min(f.rank) AS rank, max(f.field) AS field
      FROM (SELECT lf.owner_id,
                   row_number() OVER (ORDER BY lf.conservative DESC, lf.version_id) AS rank,
                   count(*) OVER () AS field
              FROM closed, ladder_field(closed.id, 'open') lf) f
     GROUP BY f.owner_id
), entrants AS (
    SELECT DISTINCT e.owner_id
      FROM closed
      JOIN model_versions v ON v.season_id = closed.id
      JOIN models e         ON e.id = v.model_id
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, data, dedupe_key)
SELECT en.owner_id, 'season', 'season', 'info',
       closed.season_name || ' has closed',
       CASE WHEN st.rank IS NULL THEN 'The final standings are in.'
            ELSE 'You finished ' || (st.rank)::text || CASE WHEN (st.rank) % 100 IN (11, 12, 13) THEN 'th' WHEN (st.rank) % 10 = 1 THEN 'st' WHEN (st.rank) % 10 = 2 THEN 'nd' WHEN (st.rank) % 10 = 3 THEN 'rd' ELSE 'th' END || ' of ' || st.field || ' on the open ladder.' END,
       '/leaderboard?season=' || closed.season,
       closed.slug, closed.season,
       jsonb_strip_nulls(jsonb_build_object('rank', st.rank, 'of', st.field, 'ladder', 'open')),
       'season-closed:' || closed.id
  FROM closed
 CROSS JOIN entrants en
  LEFT JOIN standing st ON st.owner_id = en.owner_id
 WHERE notification_wanted(en.owner_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
