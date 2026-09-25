-- THE CALLER'S OWN HELD COMMENTS ON ONE HOST, oldest first: the public thread is cached under a key
-- with no caller in it, so the author's "waiting for review" rows come from here and web places
-- them in the thread. The host is named as /v1/threads names it.
SELECT ls.sid AS session_ok,
       json_build_object('comments', coalesce((
           SELECT json_agg(comment_json(c)::jsonb || jsonb_build_object('mine', true)
                           ORDER BY c.created_at, c.id)
             FROM threads t
             JOIN comments c ON c.thread_id = t.id AND c.author_id = ls.user_id AND c.state = 'held'
            WHERE t.match_id = try_uuid(($3)::text) OR t.model_id = try_uuid(($4)::text)),
           '[]'::json)) AS body
  FROM live_sessions ls
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
