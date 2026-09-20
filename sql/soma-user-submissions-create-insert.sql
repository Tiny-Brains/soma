INSERT INTO model_versions (model_id, game_id, season_id, version, weights_hash, manifest_hash)
SELECT e.id, g.id, s.id, coalesce(max(v.version), 0) + 1, ($5)::text, ($6)::text
FROM games g
JOIN seasons s ON s.game_id = g.id
AND s.closed_at IS NULL
AND s.submissions_open_at <= now()
AND now() < s.submissions_close_at
JOIN models e ON e.game_id = g.id
AND e.owner_id = ($1)::uuid
AND e.retired_at IS NULL
AND e.id = ($3)::uuid
JOIN live_sessions ls ON ls.sid = ($4)::uuid
AND ls.user_id = ($1)::uuid
LEFT JOIN model_versions v ON v.model_id = e.id
WHERE g.slug = ($2)::text
AND season_admits(s, ($1)::uuid)
AND season_admits_weights(s, ($1)::uuid, ($5)::text, e.id)
AND season_admits_in_flight(s, ($1)::uuid)
AND season_admits_version(s, ($1)::uuid, e.id)
AND season_admits_cooldown(s, e.id)
AND NOT EXISTS (SELECT 1
    FROM model_versions f
    WHERE f.model_id = e.id
    AND f.status IN ('testing', 'verified'))
GROUP BY e.id, g.id, s.id
