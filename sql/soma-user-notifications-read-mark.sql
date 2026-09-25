UPDATE notifications n
SET read_at = now()
FROM live_sessions ls
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
AND n.user_id = ls.user_id
AND n.read_at IS NULL
AND (($4)::text IS NULL
    OR n.category = ($4)::text)
AND (($3)::boolean
    OR n.id IN (SELECT jsonb_uuids(($5)::jsonb)))
