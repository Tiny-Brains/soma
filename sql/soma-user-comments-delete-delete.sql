-- THE AUTHOR TAKES THEIR OWN COMMENT DOWN: an UPDATE to `deleted`, since soma-db refuses DELETE,
-- and the row stays as a placeholder while replies hang beneath it. The thread's live count is the
-- trigger's, so rows_affected is 1 exactly when the comment was taken down.
UPDATE comments c
   SET state = 'deleted'
  FROM live_sessions ls
 WHERE c.id = try_uuid(($3)::text)
   AND ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid AND c.author_id = ls.user_id
   AND c.state IN ('live', 'held')
