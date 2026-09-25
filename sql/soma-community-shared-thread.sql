-- A HOST'S THREAD, made on its first comment, or when an admin locks a host nobody has commented on
-- yet. Idempotent, and guarded by the caller's live session and thread_host_ok(): a match nobody may
-- see, a trial in progress among them, never gets one. The lock route's admin check is its own.
INSERT INTO threads (match_id, model_id)
SELECT try_uuid(($3)::text), try_uuid(($4)::text)
  FROM live_sessions ls
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
   AND thread_host_ok(try_uuid(($3)::text), try_uuid(($4)::text))
ON CONFLICT DO NOTHING
