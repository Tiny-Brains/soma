SELECT json_build_object('found', true, 'closed', se.closed_at IS NOT NULL, 'status', v.status, 'reject_reason',
        v.reject_reason) AS body
FROM model_versions v
JOIN models e ON e.id = v.model_id
JOIN users u ON u.id = e.owner_id
AND u.role = 'baseline'
JOIN seasons se ON se.id = v.season_id
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND lower(u.handle) = lower('baseline.' || ($3)::text)
ORDER BY (v.status <> 'rejected') DESC, v.created_at DESC
LIMIT 1
