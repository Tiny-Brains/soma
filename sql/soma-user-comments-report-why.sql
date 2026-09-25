SELECT ls.sid AS session_ok,
       json_build_object('found', c.id IS NOT NULL, 'own', c.author_id = ls.user_id) AS body
  FROM live_sessions ls
  LEFT JOIN comments c ON c.id = try_uuid(($3)::text) AND c.state = 'live'
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
