SELECT json_build_object( 'slug', season_slug(btrim(($3)::text)), 'name_usable', char_length(btrim(($3)::text))
        BETWEEN 1
    AND 48
    AND season_slug(btrim(($3)::text)) ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    AND char_length(season_slug(btrim(($3)::text))) <= 48
    AND season_slug(btrim(($3)::text)) NOT IN ('current', 'live', 'latest', 'new'), 'taken_by', (SELECT
            s.name
        FROM seasons s
        WHERE s.game_id = g.id
        AND s.slug = season_slug(btrim(($3)::text))), 'live', (SELECT json_build_object('slug', s.slug,
                'name', s.name, 'closed_at', s.closed_at)
        FROM seasons s
        WHERE s.game_id = g.id
        AND s.closed_at IS NULL), 'earliest_open', (SELECT max(s.closed_at) + make_interval(days =>
                ($2)::int)
        FROM seasons s
        WHERE s.game_id = g.id), 'engine', g.active_engine_digest IS NOT NULL) AS body
FROM games g
WHERE g.slug = ($1)::text
