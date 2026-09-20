SELECT ls.sid AS session_ok, json_build_object('category', ($3)::text, 'known', sp.category IS NOT
        NULL, 'receivable', cur.category IS NOT NULL, 'locked', coalesce(sp.locked, false), 'levels',
        sp.levels) AS body
FROM (SELECT 1) AS one
LEFT JOIN live_sessions ls ON ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
LEFT JOIN notification_category_spec() sp ON sp.category = ($3)::text
LEFT JOIN LATERAL notification_settings_of(ls.user_id) cur ON cur.category = sp.category
