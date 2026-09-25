SELECT json_build_object(
    'thread_id', t.id,
    'host',      thread_host(t),
    'host_id',   thread_host_id(t),
    'comments',  t.comments,
    'locked',    t.locked_at IS NOT NULL,
    'locked_at', t.locked_at,
    'locked_by', (SELECT u.handle FROM users u WHERE u.id = t.locked_by)) AS body
  FROM threads t
 WHERE t.id = try_uuid(($3)::text) OR t.match_id = try_uuid(($1)::text) OR t.model_id = try_uuid(($2)::text)
