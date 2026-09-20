SELECT json_build_object('model_id', e.id, 'model', e.name, 'name_taken', ($2)::text IS NOT NULL
    AND EXISTS (SELECT 1
        FROM models o
        WHERE o.owner_id = e.owner_id
        AND o.game_id = e.game_id
        AND o.id <> e.id
        AND lower(o.name) = lower(btrim(($2)::text)))) AS body
FROM models e
WHERE e.id = ($1)::uuid
AND e.owner_id = ($3)::uuid
