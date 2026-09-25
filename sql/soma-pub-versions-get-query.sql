SELECT version_json(v, ($2)::float8) AS body
FROM model_versions v
WHERE v.id = ($1)::uuid
AND version_public(v.status)
