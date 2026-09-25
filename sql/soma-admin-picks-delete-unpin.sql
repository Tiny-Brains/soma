-- Unpinned, never deleted, and its audit line.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), gone AS (
    UPDATE picks p
       SET unpinned_at = now(), unpinned_by = me.id
      FROM me
     WHERE p.id = try_uuid(($3)::text) AND p.unpinned_at IS NULL
    RETURNING p.id, p.match_id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'pick.unpin', 'match', gone.match_id::text, jsonb_build_object('pick', gone.id)
  FROM gone, me
