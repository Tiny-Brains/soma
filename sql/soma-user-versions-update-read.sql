SELECT ls.sid AS session_ok, text_hold_tag(($4)::text, false) AS note_word,
       (SELECT version_json(v, ($5)::float8)
          FROM model_versions v
         WHERE v.id = ($1)::uuid
           AND model_writable_by(v.model_id, ls.user_id)) AS body
  FROM live_sessions ls
 WHERE ls.sid = ($3)::uuid AND ls.user_id = ($2)::uuid
