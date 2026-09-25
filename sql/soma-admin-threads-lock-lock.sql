-- LOCK OR UNLOCK ONE THREAD, named by its id or its host, with its audit line. Only a thread not
-- already in the asked state changes, so asking twice writes one line.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), flipped AS (
    UPDATE threads t
       SET locked_at = CASE WHEN ($6)::boolean THEN now() END,
           locked_by = CASE WHEN ($6)::boolean THEN me.id END
      FROM me
     WHERE (t.id = try_uuid(($5)::text) OR t.match_id = try_uuid(($3)::text) OR t.model_id = try_uuid(($4)::text))
       AND (t.locked_at IS NOT NULL) <> ($6)::boolean
    RETURNING t
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, reason, detail)
SELECT me.id, CASE WHEN ($6)::boolean THEN 'thread.lock' ELSE 'thread.unlock' END, 'thread', (f.t).id::text,
       nullif(btrim(coalesce(($7)::text, '')), ''),
       jsonb_build_object('host', thread_host(f.t), 'host_id', thread_host_id(f.t))
  FROM flipped f, me
