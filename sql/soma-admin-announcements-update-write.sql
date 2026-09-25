-- Disable, and its audit line. The bar drops it on its next read.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), off AS (
    UPDATE announcements a
       SET disabled_at = now(), disabled_by = me.id
      FROM me
     WHERE a.id = ($3)::uuid AND a.disabled_at IS NULL
    RETURNING a.id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id)
SELECT me.id, 'announcement.disable', 'announcement', off.id::text
  FROM off, me
