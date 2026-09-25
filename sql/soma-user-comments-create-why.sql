-- WHY NOTHING WAS WRITTEN, read back through the same functions the post asks: comment_wait()'s
-- `wait_s` and `day_wait_s`, line_ok(), thread_host_ok() and the commenting switch.
WITH me AS (
    SELECT u AS u, true AS live
      FROM live_sessions ls JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), t AS (
    SELECT t.id, t.locked_at FROM threads t
     WHERE t.match_id = try_uuid(($3)::text) OR t.model_id = try_uuid(($4)::text)
)
SELECT coalesce(me.live, false) AS session_ok, json_build_object(
    'body_ok',    line_ok(btrim(($6)::text), 500),
    'host_ok',    thread_host_ok(try_uuid(($3)::text), try_uuid(($4)::text)),
    'parent_ok',  ($5)::text IS NULL
                  OR EXISTS (SELECT 1 FROM comments c JOIN t ON t.id = c.thread_id
                              WHERE c.id = try_uuid(($5)::text) AND c.state = 'live'),
    'off_until',  commenting_off_until(me.u),
    'off_reason', commenting_off_reason(me.u),
    'locked',     coalesce((SELECT t.locked_at IS NOT NULL FROM t), false),
    'wait_s',     w.wait_s,
    'day_wait_s', w.day_wait_s) AS body
  FROM (SELECT 1) one
  LEFT JOIN me ON true
  LEFT JOIN LATERAL comment_wait((me.u).id) w ON true
