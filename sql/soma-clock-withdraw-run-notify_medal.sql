-- One medal per placed owner per ladder, read off the frozen podium of EACH season that just closed
-- (N30: seasons overlap, so a tick may close more than one). `closed` is every season of the game
-- closed in the last few minutes -- every season this tick's close wrote, since it stamps closed_at =
-- now() -- and season_podium is joined per season, so two seasons settling in one tick each award
-- their medals. Keyed `medal:<season>:<ladder>`, so a rerun -- or an old season still inside the
-- window -- inserts nothing. Category `season`.
WITH closed AS (
    SELECT s.id, s.slug AS season, s.name AS season_name, g.slug
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NOT NULL
       AND s.closed_at >= now() - interval '5 minutes'
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, data, dedupe_key)
SELECT p.owner_id, 'season', 'medal', 'ok',
       closed.season_name || ': ' || CASE p.place WHEN 1 THEN 'first' WHEN 2 THEN 'second' ELSE 'third' END
         || ' on the ' || p.ladder || ' ladder',
       e.name || ' v' || v.version || ' closed the season at ' || to_char(p.rating, 'FM9990.00') || '.',
       '/leaderboard?season=' || closed.season || '&ladder=' || p.ladder,
       closed.slug, closed.season, e.id, v.id,
       jsonb_build_object('place', p.place, 'ladder', p.ladder, 'rating', round(p.rating::numeric, 2),
                          'model', e.name, 'version', v.version),
       'medal:' || closed.id || ':' || p.ladder
  FROM closed
  JOIN season_podium p  ON p.season_id = closed.id
  JOIN model_versions v ON v.id = p.version_id
  JOIN models e         ON e.id = v.model_id
 WHERE notification_wanted(p.owner_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
