-- SCHEDULE THE NEXT ROUND of every live season of the game played in rounds (`rules.rounds`), when
-- none is waiting. Rounds fall on a grid from the window's open, every `days`: the first AT the open
-- (a round there is the season starting, so it is born announced -- there is nothing to count down
-- to and no rating to reset), and each later one on the first grid point after both the last
-- round's start and now -- so a round an admin cancelled is skipped, not re-made, and a clock that
-- was down does not queue the weeks it missed. Only inside the window: the season freezes at its
-- close, and what follows it is the admin's finals, which this never schedules. Idempotent: the
-- one-waiting index refuses a second, and a conflict inserts nothing.
WITH s AS (
    SELECT se.id, se.submissions_open_at AS open_at, se.submissions_close_at AS close_at,
           coalesce((se.rules -> 'rounds' ->> 'days')::int, 7)                 AS days,
           coalesce((se.rules -> 'rounds' ->> 'games')::int, 100)              AS games,
           (se.rules -> 'rounds' ->> 'sigma_floor')::float8                     AS sigma_floor,
           coalesce((se.rules -> 'rounds' ->> 'mu_shrink')::float8, 0)          AS mu_shrink,
           coalesce((se.rules -> 'rounds' ->> 'warn_minutes')::int, 15)         AS warn_minutes,
           (SELECT max(r.n) FROM season_rounds r WHERE r.season_id = se.id)         AS last_n,
           (SELECT max(r.starts_at) FROM season_rounds r WHERE r.season_id = se.id) AS last_at
      FROM seasons se
     WHERE se.game_id = ($1)::uuid AND se.closed_at IS NULL
       AND se.submissions_close_at > now()
       AND coalesce((se.rules -> 'rounds' ->> 'enabled')::boolean, false)
       AND NOT EXISTS (SELECT 1 FROM season_rounds w
                        WHERE w.season_id = se.id AND w.applied_at IS NULL AND w.cancelled_at IS NULL)
), next AS (
    SELECT s.*,
           CASE WHEN s.last_n IS NULL THEN s.open_at
                ELSE s.open_at + make_interval(days => s.days)
                     * (floor(extract(epoch FROM greatest(s.last_at, now()) - s.open_at)
                              / (s.days * 86400.0)) + 1)
           END AS starts_at
      FROM s
)
INSERT INTO season_rounds (season_id, n, kind, starts_at, games, sigma_floor, mu_shrink,
                           warn_minutes, announced_at)
SELECT n.id, coalesce(n.last_n, 0) + 1, 'round', n.starts_at, n.games, n.sigma_floor, n.mu_shrink,
       n.warn_minutes, CASE WHEN n.last_n IS NULL THEN now() END
  FROM next n
 WHERE n.starts_at < n.close_at
ON CONFLICT DO NOTHING
