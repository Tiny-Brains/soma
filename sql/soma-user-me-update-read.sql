SELECT ls.sid AS session_ok, text_hold_tag(($3)::jsonb ->> 'bio', false) AS bio_word,
    json_build_object('id', u.id, 'handle', u.handle, 'display_name', u.display_name, 'bio', u.bio,
        'role', u.role, 'created_at', u.created_at) AS body
FROM live_sessions ls
JOIN users u ON u.id = ls.user_id
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
