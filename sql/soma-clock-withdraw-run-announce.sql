-- THE COUNTDOWN: every waiting round of a live season of the game whose warning has come
-- (`warn_minutes` before its start; 0 is none) gets one line across every page, and is stamped
-- announced so it gets one only. The line names the season and what happens -- "Nuptial Flight:
-- scores reset" -- and carries the instant as `at`, which web draws as a live "in 14 min", so the
-- words never go stale; it ends at the start. `source` names the round and is unique, so a rerun or
-- a round an admin moved posts nothing twice (the admin's edit moves the line's `at` with it).
-- A PRIVATE season's countdown is not on the public site: it is stamped and its entrants are told
-- through the bell (notify_round) instead.
WITH due AS (
    SELECT r.season_id, r.n, r.kind, r.starts_at, s.name, s.slug, s.visibility
      FROM season_rounds r
      JOIN seasons s ON s.id = r.season_id AND s.closed_at IS NULL
     WHERE s.game_id = ($1)::uuid
       AND r.applied_at IS NULL AND r.cancelled_at IS NULL AND r.announced_at IS NULL
       AND r.warn_minutes > 0
       AND now() >= r.starts_at - make_interval(mins => r.warn_minutes)
       FOR UPDATE OF r
), posted AS (
    INSERT INTO announcements (kind, body, link, dismissable, ends_at, season_id, at, source)
    SELECT 'season',
           d.name || CASE WHEN d.kind = 'finals' THEN ': finals start' ELSE ': scores reset' END,
           '/leaderboard?season=' || d.slug, true, d.starts_at, d.season_id, d.starts_at,
           'round:' || d.season_id || ':' || d.n
      FROM due d
     WHERE d.visibility = 'public'
    ON CONFLICT (source) DO NOTHING
)
UPDATE season_rounds r
   SET announced_at = now()
  FROM due
 WHERE r.season_id = due.season_id AND r.n = due.n
