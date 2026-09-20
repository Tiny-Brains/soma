INSERT INTO notification_settings AS ns (user_id, category, app, push, level, updated_at)
SELECT ls.user_id, cur.category, coalesce(($4)::boolean, cur.app),
coalesce(($5)::boolean, cur.push),
CASE
WHEN sp.levels IS NOT NULL THEN coalesce(($6)::text, cur.level)
END, now()
FROM live_sessions ls
JOIN LATERAL notification_settings_of(ls.user_id) cur ON cur.category = ($3)::text
JOIN notification_category_spec() sp ON sp.category = cur.category
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
AND NOT (sp.locked
    AND ($4)::boolean IS FALSE)
AND (($6)::text IS NULL
    OR ($6)::text = ANY (sp.levels))
ON CONFLICT (user_id, category) DO
UPDATE
SET app = coalesce(($4)::boolean, ns.app),
push = coalesce(($5)::boolean, ns.push),
level = CASE
WHEN ns.level IS NULL THEN NULL
ELSE coalesce(($6)::text, ns.level)
END, updated_at = now()
