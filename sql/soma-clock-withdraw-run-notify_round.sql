-- "Scores are about to reset": one row per entrant of each season whose round was announced in the
-- last few minutes -- every round this tick's announce stamped -- keyed `round:<season>:<n>`,
-- category `season`, so a rerun inserts nothing. Entrants are the owners of the season's active
-- versions, baselines left out. `data.at` is the instant, which the bell can count down to.
WITH told AS (
    SELECT r.season_id, r.n, r.kind, r.starts_at, r.games, s.name, s.slug AS season, g.slug AS game
      FROM season_rounds r
      JOIN seasons s ON s.id = r.season_id AND s.closed_at IS NULL
      JOIN games g   ON g.id = s.game_id
     WHERE s.game_id = ($1)::uuid
       AND r.announced_at >= now() - interval '5 minutes'
       AND r.applied_at IS NULL AND r.cancelled_at IS NULL
       AND r.warn_minutes > 0
), entrants AS (
    SELECT DISTINCT t.season_id, t.n, t.kind, t.starts_at, t.games, t.name, t.season, t.game,
           e.owner_id
      FROM told t
      JOIN model_versions v ON v.season_id = t.season_id AND v.status = 'active'
      JOIN models e         ON e.id = v.model_id
      JOIN users u          ON u.id = e.owner_id AND u.role <> 'baseline'
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, data, dedupe_key)
SELECT en.owner_id, 'season', 'season', 'info',
       en.name || CASE WHEN en.kind = 'finals' THEN ': the finals are about to start'
                       ELSE ': scores are about to reset' END,
       'Every entry plays ' || en.games || ' matches from a level start.',
       '/leaderboard?season=' || en.season,
       en.game, en.season,
       jsonb_build_object('at', en.starts_at, 'round', en.n, 'games', en.games),
       'round:' || en.season_id || ':' || en.n
  FROM entrants en
 WHERE notification_wanted(en.owner_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
