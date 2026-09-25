-- The comment as its author sees it: held or live, with where it hangs.
SELECT comment_json(c)::jsonb || jsonb_build_object(
           'mine',    true,
           'host',    thread_host(t),
           'host_id', thread_host_id(t)) AS body
  FROM comments c
  JOIN threads t ON t.id = c.thread_id
 WHERE c.id = ($1)::uuid AND c.author_id = ($2)::uuid
