SELECT json_build_object( 'name', btrim(($3)::text), 'participant', s.id IS NULL
    OR season_admits(s, ($2)::uuid), 'room', s.id IS NULL
    OR season_admits_entry(s, ($2)::uuid), 'entries_max', (s.rules -> 'entries' ->> 'max_per_user')::int,
        'entries_used', (SELECT count(*)
        FROM models e
        WHERE e.owner_id = ($2)::uuid
        AND e.game_id = g.id
        AND e.retired_at IS NULL), 'name_taken', EXISTS (SELECT 1
        FROM models e
        WHERE e.owner_id = ($2)::uuid
        AND e.game_id = g.id
        AND lower(e.name) = lower(btrim(($3)::text)))) AS body
FROM games g
LEFT JOIN seasons s ON s.game_id = g.id
AND s.closed_at IS NULL
WHERE g.slug = ($1)::text
