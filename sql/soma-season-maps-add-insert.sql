INSERT INTO season_maps (season_id, map_id, players, rows, cols, digest, board, added_by)
SELECT se.id, h.h ->> 'id', (h.h ->> 'players')::smallint, (h.h ->> 'rows')::smallint, (h.h ->> 'cols')::smallint,
    'sha256:' || encode(sha256(convert_to(($3)::jsonb::text, 'UTF8')), 'hex'),
($3)::jsonb, ($4)::uuid
FROM seasons se
JOIN games g ON g.id = se.game_id, (SELECT season_map_header(($3)::jsonb) AS h) h
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND se.closed_at IS NULL
AND h.h IS NOT NULL
ON CONFLICT DO NOTHING
