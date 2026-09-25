-- AN AUTHOR'S LIVE COMMENTS, newest first, twenty a page, keyset on (created_at, id) down
-- comments_author_idx. Each carries its host and the link a page opens it at.
WITH author AS (
    SELECT u.id, u.handle FROM users u WHERE lower(u.handle) = lower(($1)::text)
), page AS (
    SELECT c AS c, c.id, c.created_at, t AS t
      FROM author
      JOIN comments c ON c.author_id = author.id AND c.state = 'live'
      JOIN threads t  ON t.id = c.thread_id
     WHERE ($2)::text IS NULL
        OR (c.created_at, c.id) < (split_part(($2)::text, '|', 1)::timestamptz,
                                   try_uuid(split_part(($2)::text, '|', 2)))
     ORDER BY c.created_at DESC, c.id DESC
     LIMIT 20
)
SELECT json_build_object(
    'handle', author.handle,
    'comments', coalesce((SELECT json_agg(comment_json(p.c)::jsonb || jsonb_build_object(
                    'host',      thread_host(p.t),
                    'host_id',   thread_host_id(p.t),
                    'host_name', (SELECT e.name FROM models e WHERE e.id = (p.t).model_id),
                    'link',      comment_link(p.t, p.id))
                    ORDER BY p.created_at DESC, p.id DESC)
                   FROM page p), '[]'::json),
    'next_cursor', CASE WHEN (SELECT count(*) FROM page) = 20
                        THEN (SELECT (to_json(p.created_at) #>> '{}') || '|' || p.id::text
                                FROM page p ORDER BY p.created_at, p.id LIMIT 1) END) AS body
  FROM author
