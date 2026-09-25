SELECT ls.sid AS session_ok, version_json(v, ($4)::float8) AS body
FROM live_sessions ls
LEFT JOIN model_versions v ON v.id = ($3)::uuid
AND model_writable_by(v.model_id, ls.user_id)
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
