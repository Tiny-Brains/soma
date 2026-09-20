SELECT ls.sid AS session_ok, (($3)::text IS NULL
    OR notification_category_ok(($3)::text)) AS category_ok, (SELECT json_agg(sp.category
        ORDER BY sp.ord)
    FROM notification_category_spec() sp) AS categories, json_build_object('unread', (SELECT count(*)
        FROM notifications n
        WHERE n.user_id = ls.user_id
        AND n.read_at IS NULL)) AS body
FROM live_sessions ls
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
