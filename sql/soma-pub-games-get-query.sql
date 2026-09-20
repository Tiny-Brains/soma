SELECT json_build_object( 'id', g.slug, 'name', g.name, 'about', g.manifest -> 'about', 'limits',
        (SELECT json_build_object('boards', g.manifest -> 'limits' -> 'boards', 'turn_ms', coalesce(CASE
                WHEN (cs.rules -> 'execution' ->> 'enabled')::boolean THEN (cs.rules -> 'execution'
                        ->> 'turn_ms')::int
                END, (g.manifest -> 'limits' ->> 'turn_ms')::int), 'max_turns', coalesce(CASE
                WHEN (cs.rules -> 'execution' ->> 'enabled')::boolean THEN (cs.rules -> 'execution'
                        ->> 'max_turns')::int
                END, (g.manifest -> 'limits' ->> 'max_turns')::int))
        FROM current_season(g.id) cs), 'strike_limit', ($2)::int, 'weight_classes', (SELECT json_agg(json_build_object('class',
                    e ->> 'class', 'max_bytes', (e ->> 'max_bytes')::bigint)
            ORDER BY (e ->> 'max_bytes')::bigint)
        FROM current_season(g.id) cs, jsonb_array_elements(cs.weight_classes) AS e), 'season', (SELECT
            season_json(s)
        FROM current_season(g.id) s)) AS body
FROM games g
WHERE g.slug = ($1)::text
