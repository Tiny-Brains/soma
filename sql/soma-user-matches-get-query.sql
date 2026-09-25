SELECT ls.sid AS session_ok, mt.replay_key, CASE
    WHEN mt.id IS NOT NULL THEN match_detail_json(mt)
    END AS body
FROM live_sessions ls
LEFT JOIN matches mt ON mt.id = ($3)::uuid
AND match_seated(mt.id, ls.user_id)
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
