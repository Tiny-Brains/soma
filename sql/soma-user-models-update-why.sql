-- WHY NOTHING WAS EDITED. A row always comes back: `session_ok` says whether the caller's session is
-- still live (the write joins live_sessions, so a dead session edits nothing and would otherwise
-- read as a name refusal), and `body` is NULL when no model of theirs has this id.
WITH me AS (
    SELECT true AS live FROM live_sessions ls
     WHERE ls.sid = ($4)::uuid AND ls.user_id = ($3)::uuid
)
SELECT coalesce(me.live, false) AS session_ok,
       CASE WHEN e.id IS NULL THEN NULL ELSE json_build_object('model_id', e.id, 'model', e.name, 'name_taken', ($2)::text IS NOT NULL
    AND EXISTS (SELECT 1
        FROM models o
        WHERE o.owner_id = e.owner_id
        AND o.game_id = e.game_id
        AND o.id <> e.id
        AND lower(o.name) = lower(btrim(($2)::text)))) END AS body
  FROM (SELECT 1) one
  LEFT JOIN me ON true
  LEFT JOIN models e ON e.id = ($1)::uuid AND e.owner_id = ($3)::uuid
