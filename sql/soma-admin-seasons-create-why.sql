SELECT json_build_object( 'slug', season_slug(btrim(($2)::text)), 'name_usable', char_length(btrim(($2)::text))
        BETWEEN 1
    AND 48
    AND season_slug(btrim(($2)::text)) ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    AND char_length(season_slug(btrim(($2)::text))) <= 48
    AND season_slug(btrim(($2)::text)) NOT IN ('current', 'live', 'latest', 'new'), 'taken_by', (SELECT
            s.name
        FROM seasons s
        WHERE s.game_id = g.id
        AND s.slug = season_slug(btrim(($2)::text))), 'engine', g.active_engine_digest IS NOT NULL) AS body
FROM games g
WHERE g.slug = ($1)::text
