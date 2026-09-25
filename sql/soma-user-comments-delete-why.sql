SELECT ls.sid AS session_ok,
       (SELECT c.state FROM comments c WHERE c.id = try_uuid(($3)::text) AND c.author_id = ls.user_id) AS state
  FROM live_sessions ls
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
