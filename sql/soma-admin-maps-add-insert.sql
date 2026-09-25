WITH added AS (INSERT INTO season_maps (season_id, map_id, players, rows, cols, size, terrain, hills, digest,
        board, added_by)
    SELECT se.id, h.h ->> 'id', (h.h ->> 'players')::smallint, (h.h ->> 'rows')::smallint, (h.h ->> 'cols')::smallint,
        n.n ->> 'size', n.n ->> 'terrain', (n.n ->> 'hills')::smallint,
        'sha256:' || encode(sha256(convert_to(($3)::jsonb::text, 'UTF8')), 'hex'),
    ($3)::jsonb, ($4)::uuid
    FROM seasons se
    JOIN games g ON g.id = se.game_id, (SELECT season_map_header(($3)::jsonb) AS h) h,
    LATERAL (SELECT season_map_name(h.h ->> 'id') AS n) n
    WHERE g.slug = ($1)::text
    AND se.slug = ($2)::text
    AND se.closed_at IS NULL
    AND h.h IS NOT NULL
    AND season_map_name_problem(h.h) IS NULL
    ON CONFLICT DO NOTHING
    RETURNING map_id)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'map.add', 'season_map', added.map_id, jsonb_build_object('game', ($1)::text, 'season',
        ($2)::text)
FROM added
