WITH mine AS NOT MATERIALIZED (
    SELECT mt.id, mt.game_id, mt.season_id, mt.status, (SELECT sm.map_id
        FROM season_maps sm
        WHERE sm.id = mt.season_map_id) AS map_id, mt.seed, mt.reason, mt.turns, mt.played_at, mt.created_at,
        mt.ladders, mt.trial_version_id, mt.withdrawn_reason, mt.successor_version_id, mt.fault_reason,
        mt.fault_seat, coalesce(mt.played_at, mt.created_at) AS at
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
    SELECT *
    FROM mine
    WHERE ($4)::text IS NULL
    OR (at, id) < (split_part(($4)::text, '|', 1)::timestamptz, split_part(($4)::text, '|', 2)::uuid)
    ORDER BY at DESC, id DESC
    LIMIT ($5)::int )
SELECT ls.sid AS session_ok, json_build_object( 'total', CASE
    WHEN ($4)::text IS NULL THEN (SELECT count(*)
        FROM mine)
    END, 'matches', coalesce((SELECT json_agg(json_build_object( 'id', p.id, 'game', (SELECT g.slug
                        FROM games g
                        WHERE g.id = p.game_id), 'season', (SELECT se.slug
                        FROM seasons se
                        WHERE se.id = p.season_id), 'status', p.status, 'map', p.map_id, 'seed', p.seed,
                        'reason', p.reason, 'turns', p.turns, 'played_at', p.played_at, 'created_at',
                        p.created_at, 'ladders', array_to_json(p.ladders), 'is_trial', p.trial_version_id
                        IS NOT NULL, 'withdrawn_reason', p.withdrawn_reason, 'fault_reason', p.fault_reason,
                        'fault_seat', p.fault_seat, 'successor', (SELECT json_build_object('version_id',
                            sv.id, 'model_id', sv.model_id, 'version', sv.version)
                        FROM model_versions sv
                        WHERE sv.id = p.successor_version_id), 'seats', (SELECT coalesce(json_agg(json_build_object(
                            'seat', s.seat, 'version_id', s.version_id, 'model_id', s.model_id, 'model',
                            s.model_name, 'owner', s.owner, 'baseline', s.baseline, 'class', s.class,
                            'version', s.version, 'rank', s.rank, 'score', s.score, 'strikes', s.strikes,
                            'mine', s.owner_id = ($1)::uuid, 'outcome', s.outcome)
                        ORDER BY s.seat), '[]'::json)
                        FROM match_seat_rows(p.id) s) )
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
