-- WHY NOTHING WAS INSERTED, a row always: `session_ok` first (the insert joins live_sessions, so a
-- dead session writes nothing and would otherwise read as a name refusal), then `found` (the 404),
-- then `name_taken` (the 409). An entry is per game and per season nothing (N30/C1), so there is no
-- participation or entry-cap reason here any more -- those are the submission's.
WITH me AS (
    SELECT true AS live FROM live_sessions ls
     WHERE ls.sid = ($4)::uuid AND ls.user_id = ($2)::uuid
)
SELECT coalesce(me.live, false) AS session_ok, json_build_object(
    'found', g.id IS NOT NULL,
    'name', btrim(($3)::text),
    'name_ok', btrim(($3)::text) <> '' AND length(btrim(($3)::text)) <= 64,
    'name_taken', EXISTS (SELECT 1
        FROM models e
        WHERE e.owner_id = ($2)::uuid
        AND e.game_id = g.id
        AND lower(e.name) = lower(btrim(($3)::text)))) AS body
FROM (SELECT 1) one
LEFT JOIN games g ON g.slug = ($1)::text
LEFT JOIN me ON true
