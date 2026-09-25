-- What people watch, per day since `since` (default 30 days): visits, matches opened -- in all and
-- by how the viewer got there -- and replays watched to the end, summed over the shards. Admin
-- only: the live admin session is joined here as on every admin read.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), d AS (
    SELECT coalesce(($3)::date, current_date - 30) AS since
), cells AS (
    SELECT w.day, w.event, w.via, sum(w.n) AS n
      FROM watch_events w, d, me
     WHERE w.day >= d.since
     GROUP BY w.day, w.event, w.via
), days AS (
    SELECT c.day,
           coalesce(sum(c.n) FILTER (WHERE c.event = 'visit'), 0)    AS visits,
           coalesce(sum(c.n) FILTER (WHERE c.event = 'opened'), 0)   AS opened,
           coalesce(json_object_agg(c.via, c.n) FILTER (WHERE c.event = 'opened'), '{}'::json) AS via,
           coalesce(sum(c.n) FILTER (WHERE c.event = 'finished'), 0) AS finished
      FROM cells c
     GROUP BY c.day
)
SELECT json_build_object(
        'since', (SELECT since FROM d),
        'days', coalesce((SELECT json_agg(json_build_object(
                              'day', x.day, 'visits', x.visits, 'opened', x.opened,
                              'opened_via', x.via, 'finished', x.finished) ORDER BY x.day DESC)
                            FROM days x), '[]'::json)) AS body
  FROM me
