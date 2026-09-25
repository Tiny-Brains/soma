-- TAKE A WORD OFF THE LIST: removed_at and removed_by, since soma-db refuses DELETE, and its audit
-- line. A word already off it writes nothing. Texts already held on it stay held until an admin
-- decides them.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), removed AS (
    UPDATE comment_words w
       SET removed_at = now(), removed_by = me.id
      FROM me
     WHERE w.id = try_uuid(($3)::text) AND w.removed_at IS NULL
    RETURNING w.id, w.word
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'word.remove', 'comment_word', r.id::text, jsonb_build_object('word', r.word)
  FROM removed r, me
