-- AN ADMIN'S DECISION OVER A SELECTION, in one statement: approve a held comment, remove a live or
-- held one, restore a removed one. A comment in another state is left alone, so a second click on
-- the same selection decides nothing. `o` is each row as it was, for its audit line with the
-- admin's reason -- the outer INSERT, so rows_affected is how many were decided. The threads' live
-- counts are the trigger's.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), decided AS (
    UPDATE comments c
       SET state = CASE ($4)::text WHEN 'remove' THEN 'removed' ELSE 'live' END,
           decided_at = now(), decided_by = me.id
      FROM me, comments o
     WHERE c.id IN (SELECT jsonb_uuids(($3)::jsonb)) AND o.id = c.id
       AND CASE ($4)::text WHEN 'approve' THEN c.state = 'held'
                           WHEN 'remove'  THEN c.state IN ('live', 'held')
                           WHEN 'restore' THEN c.state = 'removed'
                           ELSE false END
    RETURNING c.id, c.thread_id, o.state AS was, c.state AS now
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, reason, detail)
SELECT me.id, 'comment.' || ($4)::text, 'comment', d.id::text, nullif(btrim(coalesce(($5)::text, '')), ''),
       jsonb_build_object('from', d.was, 'to', d.now, 'thread_id', d.thread_id)
  FROM decided d, me
