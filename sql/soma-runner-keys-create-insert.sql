INSERT INTO runner_keys (user_id, label, key_hash, key_prefix)
SELECT u.id, btrim(($2)::text),
($3)::text, ($4)::text
FROM users u
JOIN live_sessions s ON s.user_id = u.id
AND s.sid = ($5)::uuid
WHERE u.id = ($1)::uuid
AND u.role = 'admin'
AND btrim(($2)::text) <> ''
