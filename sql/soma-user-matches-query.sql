WITH mine AS NOT MATERIALIZED (
    SELECT mt AS m, mt.id, coalesce(mt.played_at, mt.created_at) AS at
    FROM matches mt
    WHERE EXISTS (SELECT 1
        FROM match_seats ms
        JOIN model_versions mv ON mv.id = ms.version_id
        JOIN models me ON me.id = mv.model_id
        WHERE ms.match_id = mt.id
        AND me.owner_id = ($1)::uuid)
    AND (($3)::text IS NULL
        OR mt.game_id = (SELECT g.id
            FROM games g
            WHERE g.slug = ($3)::text)) ),
page AS (
    SELECT m, id, at
    FROM mine
    WHERE ($4)::text IS NULL
    OR (at, id) < (try_timestamptz(split_part(($4)::text, '|', 1)), try_uuid(split_part(($4)::text, '|', 2)))
    ORDER BY at DESC, id DESC
    LIMIT ($5)::int )
SELECT ls.sid AS session_ok, json_build_object( 'total', CASE
    WHEN ($4)::text IS NULL THEN (SELECT count(*)
        FROM mine)
    END, 'matches', coalesce((SELECT json_agg(match_summary_json(p.m, ($1)::uuid) || jsonb_build_object(
                    'created_at', (p.m).created_at, 'withdrawn_reason', (p.m).withdrawn_reason,
                    'fault_reason', (p.m).fault_reason, 'successor', (SELECT jsonb_build_object('version_id',
                            sv.id, 'model_id', se.id, 'model', se.name, 'owner', su.handle, 'version', sv.version)
                        FROM model_versions sv
                        JOIN models se ON se.id = sv.model_id
                        JOIN users su ON su.id = se.owner_id
                        WHERE sv.id = (p.m).successor_version_id))
                ORDER BY p.at DESC, p.id DESC)
            FROM page p), '[]'::json), 'next_cursor', CASE
    WHEN (SELECT count(*)
        FROM page) = ($5)::int THEN (SELECT (to_json(x.at) #>> '{}') || '|' || x.id::text
        FROM page x
        ORDER BY x.at ASC, x.id ASC
        LIMIT 1)
    END) AS body
FROM live_sessions ls
WHERE ls.sid = ($2)::uuid
AND ls.user_id = ($1)::uuid
