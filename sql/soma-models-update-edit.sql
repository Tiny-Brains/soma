UPDATE models e
SET name = coalesce(btrim(($4)::text), e.name),
retired_at = CASE
WHEN ($5)::bool IS NULL THEN e.retired_at
WHEN ($5)::bool THEN coalesce(e.retired_at, now())
ELSE NULL
END
FROM live_sessions ls
WHERE ls.sid = ($3)::uuid
AND ls.user_id = ($2)::uuid
AND e.owner_id = ($2)::uuid
AND e.id = ($1)::uuid
AND (($4)::text IS NULL
    OR (btrim(($4)::text) <> ''
        AND length(btrim(($4)::text)) <= 64
        AND NOT EXISTS (SELECT 1
            FROM models o
            WHERE o.owner_id = e.owner_id
            AND o.game_id = e.game_id
            AND o.id <> e.id
            AND lower(o.name) = lower(btrim(($4)::text)))))
