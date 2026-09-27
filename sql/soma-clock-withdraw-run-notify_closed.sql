-- One "the season closed" notification per entrant of EACH season that just closed (N30: seasons
-- overlap, so a tick may close more than one). `closed` is every season of the game closed in the
-- last few minutes -- which is every season this tick's close wrote, since it stamps closed_at =
-- now() -- rather than only the newest, so two seasons settling in one tick both tell their
-- entrants. entrants and standing carry the season id, and the INSERT joins standing per
-- (season, owner) and links per season, so a competitor in season A is never told about season B.
-- Keyed `season-closed:<season>`, category `season`, so a rerun -- or an old season still inside the
-- window -- inserts nothing.
WITH closed AS (
    SELECT s.id, s.slug AS season, s.name AS season_name, g.slug
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NOT NULL
       AND s.closed_at >= now() - interval '5 minutes'
), standing AS (
    -- Ranked the podium's way (owner_ranks): each owner once, by their best version, baselines
    -- left out -- so "you finished 2nd" and the podium's second place are the same person.
    SELECT c.id AS season_id, o.owner_id, o.place AS rank, o.field
      FROM closed c, owner_ranks(c.id, 'open') o
), entrants AS (
    SELECT DISTINCT c.id AS season_id, c.season, c.slug, c.season_name, e.owner_id
      FROM closed c
      JOIN model_versions v ON v.season_id = c.id
      JOIN models e         ON e.id = v.model_id
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, data, dedupe_key)
SELECT en.owner_id, 'season', 'season', 'info',
       en.season_name || ' has closed',
       CASE WHEN st.rank IS NULL THEN 'The final standings are in.'
            ELSE 'You finished ' || (st.rank)::text || CASE WHEN (st.rank) % 100 IN (11, 12, 13) THEN 'th' WHEN (st.rank) % 10 = 1 THEN 'st' WHEN (st.rank) % 10 = 2 THEN 'nd' WHEN (st.rank) % 10 = 3 THEN 'rd' ELSE 'th' END || ' of ' || st.field || ' on the open ladder.' END,
       '/leaderboard?season=' || en.season,
       en.slug, en.season,
       jsonb_strip_nulls(jsonb_build_object('rank', st.rank, 'of', st.field, 'ladder', 'open')),
       'season-closed:' || en.season_id
  FROM entrants en
  LEFT JOIN standing st ON st.season_id = en.season_id AND st.owner_id = en.owner_id
 WHERE notification_wanted(en.owner_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
