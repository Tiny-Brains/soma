SELECT json_build_object( 'found', true, 'closed', se.closed_at IS NOT NULL, 'players', sm.players,
        'board', sm.board, 'engine', json_build_object('season', se.engine_digest, 'node', ($4)::text),
        'engine_ok', se.engine_digest = ($4)::text) AS body
FROM season_maps sm
JOIN seasons se ON se.id = sm.season_id
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND sm.map_id = ($3)::text
