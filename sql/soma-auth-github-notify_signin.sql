INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, data, dedupe_key)
SELECT u.id, 'account', 'account', 'info', 'New sign-in to your account', 'Signed in from ' || coalesce(left(nullif(btrim(($3)::text),
                ''), 300), 'a browser that did not name itself') || '. If this was not you, end that session.',
    '/me/account', jsonb_build_object('sid', ($1)::uuid, 'user_agent', left(($3)::text, 300)), 'sign-in:'
    || ($1)::uuid
FROM users u
WHERE u.id = ($2)::uuid
AND EXISTS (SELECT 1
    FROM live_sessions ls
    WHERE ls.user_id = u.id
    AND ls.sid <> ($1)::uuid)
AND notification_wanted(u.id, 'account')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
