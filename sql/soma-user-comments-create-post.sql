-- THE COMMENT, with every rule a PREDICATE, so a refusal is a row never written and `why` says
-- which: a live session, commenting not switched off, comment_wait() clear, the thread not locked,
-- a parent that is a live comment of the same thread, and line_ok(body, 500). text_hold_tag() holds
-- it on a listed word or a link. The thread's live count is the trigger's.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     CROSS JOIN LATERAL comment_wait(u.id) w
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
       AND commenting_off_until(u) IS NULL
       AND w.wait_s IS NULL AND w.day_wait_s IS NULL
), t AS (
    SELECT t.id FROM threads t
     WHERE t.locked_at IS NULL
       AND (t.match_id = try_uuid(($3)::text) OR t.model_id = try_uuid(($4)::text))
), p AS (
    SELECT c.root_id, c.thread_id FROM comments c
     WHERE c.id = try_uuid(($5)::text) AND c.state = 'live'
), body AS (
    SELECT btrim(($6)::text) AS b
)
INSERT INTO comments (id, thread_id, parent_id, root_id, author_id, body, state, hold_tag)
SELECT ($7)::uuid, t.id, try_uuid(($5)::text), coalesce(p.root_id, ($7)::uuid), me.id,
       body.b, CASE WHEN h.tag IS NULL THEN 'live' ELSE 'held' END, h.tag
  FROM me
 CROSS JOIN t
 CROSS JOIN body
  LEFT JOIN p ON true
 CROSS JOIN LATERAL (SELECT text_hold_tag(body.b, true) AS tag) h
 WHERE line_ok(body.b, 500)
   AND (($5)::text IS NULL OR p.thread_id = t.id)
