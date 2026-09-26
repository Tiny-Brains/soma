-- WHY NOTHING WAS INSERTED, a row always: `found` is whether the game exists (the 404), and `session_ok` first: the insert joins live_sessions, so a dead session
-- writes nothing and would otherwise read as a participation or name refusal.
WITH me AS (
    SELECT true AS live FROM live_sessions ls
     WHERE ls.sid = ($4)::uuid AND ls.user_id = ($2)::uuid
)
SELECT coalesce(me.live, false) AS session_ok, json_build_object( 'found', g.id IS NOT NULL, 'name', btrim(($3)::text), 'participant', s.id IS NULL
    OR season_admits(s, ($2)::uuid), 'room', s.id IS NULL
    OR season_admits_entry(s, ($2)::uuid), 'entries_max', (s.rules -> 'entries' ->> 'max_per_user')::int,
        'entries_used', (SELECT count(*)
        FROM models e
        WHERE e.owner_id = ($2)::uuid
        AND e.game_id = g.id
        AND e.retired_at IS NULL), 'name_taken', EXISTS (SELECT 1
        FROM models e
        WHERE e.owner_id = ($2)::uuid
        AND e.game_id = g.id
        AND lower(e.name) = lower(btrim(($3)::text)))) AS body
FROM (SELECT 1) one
LEFT JOIN games g ON g.slug = ($1)::text
LEFT JOIN me ON true
LEFT JOIN seasons s ON s.game_id = g.id
AND s.closed_at IS NULL
