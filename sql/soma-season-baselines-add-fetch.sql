SELECT season_baseline_json(v) AS body
FROM model_versions v
JOIN models e ON e.id = v.model_id
JOIN users u ON u.id = e.owner_id
AND u.role = 'baseline'
JOIN seasons se ON se.id = v.season_id
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND lower(u.handle) = lower(baseline_handle(($3)::text))
AND v.status = 'testing'
AND v.weights_hash = ($4)::text
AND v.manifest_hash = ($5)::text
ORDER BY v.created_at DESC
LIMIT 1
