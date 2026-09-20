WITH b AS (
    SELECT ($3)::jsonb AS v ),
h AS (
    SELECT season_map_header(b.v) AS h, 'sha256:' || encode(sha256(convert_to(b.v::text, 'UTF8')),
            'hex') AS digest
    FROM b ),
se AS (
    SELECT s.id, s.closed_at, s.engine_digest, g.manifest -> 'limits' -> 'boards' AS limits
    FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text
    AND s.slug = ($2)::text )
SELECT json_build_object( 'season', EXISTS (SELECT 1
        FROM se), 'closed', (SELECT se.closed_at IS NOT NULL
        FROM se), 'header', h.h, 'limits', (SELECT se.limits
        FROM se), 'within', coalesce((SELECT season_map_within(h.h, se.limits)
            FROM se), false), 'engine', json_build_object('season', (SELECT se.engine_digest
            FROM se), 'node', ($4)::text), 'engine_ok', coalesce((SELECT se.engine_digest = ($4)::text
            FROM se), false), 'existing', (SELECT json_build_object('map_id', sm.map_id, 'enabled',
                sm.enabled, 'same_id', sm.map_id = h.h ->> 'id')
        FROM season_maps sm
        JOIN se ON se.id = sm.season_id
        WHERE sm.map_id = h.h ->> 'id'
        OR sm.digest = h.digest
        ORDER BY (sm.map_id = h.h ->> 'id') DESC
        LIMIT 1)) AS body
FROM h
