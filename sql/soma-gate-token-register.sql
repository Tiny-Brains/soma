INSERT INTO runners (key_id, label, engine_digest, node_version, orion_version, ops_budget, arch,
        last_seen_at)
SELECT k.id, btrim(($2)::text),
($3)::text, ($4)::text, ($5)::text, ($6)::bigint, ($7)::text, now()
FROM runner_keys k
JOIN users u ON u.id = k.user_id
AND u.role = 'admin'
WHERE k.key_hash = ($1)::text
AND k.revoked_at IS NULL
AND btrim(($2)::text) <> ''
ON CONFLICT (key_id, label) DO
UPDATE
SET engine_digest = EXCLUDED.engine_digest, node_version = EXCLUDED.node_version, orion_version =
    EXCLUDED.orion_version, ops_budget = EXCLUDED.ops_budget, arch = EXCLUDED.arch, last_seen_at =
    now()
