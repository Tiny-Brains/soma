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
    OR n.id IN (SELECT x::uuid
        FROM jsonb_array_elements_text( CASE
            WHEN jsonb_typeof(($5)::jsonb) = 'array' THEN ($5)::jsonb
            ELSE '[]'::jsonb
            END) AS x
        WHERE x ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
