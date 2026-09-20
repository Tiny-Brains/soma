WITH given AS (
    SELECT DISTINCT btrim(h) AS handle
    FROM unnest(CASE
        WHEN jsonb_typeof(($1)::jsonb) = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(($1)::jsonb))
        ELSE regexp_split_to_array(($1)::jsonb #>> '{}', '\s*,\s*')
        END) AS h
    WHERE btrim(h) <> '' )
SELECT coalesce(jsonb_agg(g.handle
        ORDER BY g.handle), '[]'::jsonb) AS handles, coalesce(jsonb_agg(u.id::text
        ORDER BY u.handle) FILTER (WHERE u.id IS NOT NULL), '[]'::jsonb) AS ids, coalesce(jsonb_agg(g.handle
        ORDER BY g.handle) FILTER (WHERE u.id IS NULL), '[]'::jsonb) AS unresolved
FROM given g
LEFT JOIN users u ON lower(u.handle) = lower(g.handle)
