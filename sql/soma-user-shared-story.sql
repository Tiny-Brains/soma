-- THE WRITER'S VIEW OF A STORY: the approved text the public reads, and the held edit beside it.
-- live_sessions is the outer FROM, so a live session always yields a row: no row is a 401, a null
-- body a model the caller may not write, and a body of nulls a model with no story yet.
SELECT ls.sid AS session_ok,
       (SELECT json_build_object(
                   'model_id', e.id, 'model', e.name, 'title', s.title, 'body', s.body,
                   'pending', story_pending_json(s),
                   'featured_at', s.featured_at, 'approved_at', s.approved_at,
                   'updated_at', s.updated_at, 'removed', s.removed_at IS NOT NULL)
          FROM models e
          LEFT JOIN model_stories s ON s.model_id = e.id
         WHERE e.id = ($1)::uuid
           AND model_writable_by(e.id, ls.user_id)) AS body
  FROM live_sessions ls
 WHERE ls.sid = ($3)::uuid AND ls.user_id = ($2)::uuid
