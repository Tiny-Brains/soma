-- ONE ACTION, and the WHERE is its precondition, so an action on a story in the wrong state writes
-- nothing: feature needs an approved text that is not removed; approve and reject a held edit;
-- remove and restore their opposites. Approve moves the edit into the public text.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), done AS (
    UPDATE model_stories s
       SET featured_at   = CASE ($4)::text WHEN 'feature' THEN now() WHEN 'unfeature' THEN NULL
                                           ELSE s.featured_at END,
           title         = CASE WHEN ($4)::text = 'approve' THEN s.pending_title ELSE s.title END,
           body          = CASE WHEN ($4)::text = 'approve' THEN s.pending_body ELSE s.body END,
           approved_at   = CASE WHEN ($4)::text = 'approve' THEN now() ELSE s.approved_at END,
           pending_title = CASE WHEN ($4)::text IN ('approve', 'reject') THEN NULL ELSE s.pending_title END,
           pending_body  = CASE WHEN ($4)::text IN ('approve', 'reject') THEN NULL ELSE s.pending_body END,
           hold_tag      = CASE WHEN ($4)::text IN ('approve', 'reject') THEN NULL ELSE s.hold_tag END,
           removed_at    = CASE ($4)::text WHEN 'remove' THEN now() WHEN 'restore' THEN NULL
                                           ELSE s.removed_at END
      FROM me
     WHERE s.model_id = ($3)::uuid
       AND CASE ($4)::text
               WHEN 'feature'   THEN s.featured_at IS NULL AND s.removed_at IS NULL AND s.title IS NOT NULL
               WHEN 'unfeature' THEN s.featured_at IS NOT NULL
               WHEN 'approve'   THEN s.hold_tag IS NOT NULL AND s.pending_title IS NOT NULL
               WHEN 'reject'    THEN s.hold_tag IS NOT NULL
               WHEN 'remove'    THEN s.removed_at IS NULL
               WHEN 'restore'   THEN s.removed_at IS NOT NULL
               ELSE false END
    RETURNING s.model_id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, reason)
SELECT me.id, 'story.' || ($4)::text, 'model', done.model_id::text, nullif(btrim(coalesce(($5)::text, '')), '')
  FROM done, me
