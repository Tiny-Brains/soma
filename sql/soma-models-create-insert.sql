INSERT INTO models (owner_id, game_id, name)
SELECT ($1)::uuid, g.id, btrim(($3)::text)
FROM games g
JOIN live_sessions ls ON ls.sid = ($4)::uuid
AND ls.user_id = ($1)::uuid
LEFT JOIN seasons s ON s.game_id = g.id
AND s.closed_at IS NULL
WHERE g.slug = ($2)::text
AND btrim(($3)::text) <> ''
AND length(btrim(($3)::text)) <= 64
AND (s.id IS NULL
    OR season_admits(s, ($1)::uuid))
AND (s.id IS NULL
    OR season_admits_entry(s, ($1)::uuid))
AND NOT EXISTS (SELECT 1
    FROM models e
    WHERE e.owner_id = ($1)::uuid
    AND e.game_id = g.id
    AND lower(e.name) = lower(btrim(($3)::text)))
