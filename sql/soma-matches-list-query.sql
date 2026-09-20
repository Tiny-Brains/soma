WITH season AS (
    SELECT s.id, s.slug
    FROM games g, current_season(g.id, ($2)::text) s
    WHERE ($1)::text IS NOT NULL
    AND g.slug = ($1)::text ),
matched AS NOT MATERIALIZED (
    SELECT mt.id, mt.game_id, mt.season_id, mt.status, (SELECT sm.map_id
        FROM season_maps sm
        WHERE sm.id = mt.season_map_id) AS map_id, mt.seed, mt.reason, mt.turns, mt.played_at, mt.ladders,
        mt.trial_version_id
    FROM matches mt
    WHERE mt.status IN ('finished', 'rated')
    AND (($1)::text IS NULL
        OR mt.season_id = (SELECT id
            FROM season))
    AND ((($9)::uuid IS NOT NULL
            OR ($11)::uuid IS NOT NULL)
        OR mt.trial_version_id IS NULL)
    AND (($9)::uuid IS NULL
        OR EXISTS (SELECT 1
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            WHERE ms.match_id = mt.id
            AND mv.model_id = ($9)::uuid))
    AND (($11)::uuid IS NULL
        OR EXISTS (SELECT 1
            FROM match_seats ms
            WHERE ms.match_id = mt.id
            AND ms.version_id = ($11)::uuid))
    AND (($10)::text IS NULL
        OR EXISTS (SELECT 1
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            JOIN models me ON me.id = mv.model_id
            JOIN users ou ON ou.id = me.owner_id
            WHERE ms.match_id = mt.id
            AND lower(ou.handle) = lower(($10)::text)))
    AND (($3)::text IS NULL
        OR ($3)::ladder = ANY (mt.ladders))
    AND (($4)::text IS NULL
        OR EXISTS (SELECT 1
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            WHERE ms.match_id = mt.id
            AND mv.weight_class = ($4)::ladder))
    AND (($5)::text IS NULL
        OR EXISTS (SELECT 1
            FROM season_maps sm
            WHERE sm.id = mt.season_map_id
            AND sm.map_id = ($5)::text))
    AND (($12)::int IS NULL
        OR mt.seat_count >= ($12)::int)
    AND (($13)::int IS NULL
        OR mt.seat_count <= ($13)::int)
    AND (($6)::text IS NULL
        OR CASE ($6)::text
        WHEN 'dq' THEN EXISTS (SELECT 1
            FROM match_seats ms
            WHERE ms.match_id = mt.id
            AND ms.strikes >= mt.strike_ceiling)
        WHEN 'drawn' THEN (SELECT count(*)
            FROM match_seats ms
            WHERE ms.match_id = mt.id
            AND ms.rank = 1) > 1
        WHEN 'decided' THEN (SELECT count(*)
            FROM match_seats ms
            WHERE ms.match_id = mt.id
            AND ms.rank = 1) = 1
        ELSE true
        END) ),
page AS (
    SELECT *
    FROM matched
    WHERE ($7)::text IS NULL
    OR (played_at, id) < (split_part(($7)::text, '|', 1)::timestamptz, split_part(($7)::text, '|',
                2)::uuid)
    ORDER BY played_at DESC, id DESC
    LIMIT ($8)::int )
SELECT json_build_object( 'season', (SELECT slug
        FROM season), 'total', CASE
    WHEN ($7)::text IS NULL THEN (SELECT count(*)
        FROM matched)
    END, 'matches', coalesce((SELECT json_agg(json_build_object( 'id', p.id, 'game', (SELECT g.slug
                        FROM games g
                        WHERE g.id = p.game_id), 'season', (SELECT se.slug
                        FROM seasons se
                        WHERE se.id = p.season_id), 'status', p.status, 'map', p.map_id, 'seed', p.seed,
                        'reason', p.reason, 'turns', p.turns, 'played_at', p.played_at, 'ladders',
                        array_to_json(p.ladders), 'is_trial', p.trial_version_id IS NOT NULL, 'seats',
                        (SELECT coalesce(json_agg(json_build_object( 'seat', s.seat, 'version_id',
                            s.version_id, 'model_id', s.model_id, 'model', s.model_name, 'owner',
                            s.owner, 'baseline', s.baseline, 'class', s.class, 'version', s.version,
                            'rank', s.rank, 'score', s.score, 'strikes', s.strikes, 'outcome', s.outcome)
                        ORDER BY s.seat), '[]'::json)
                        FROM match_seat_rows(p.id) s) )
                ORDER BY p.played_at DESC, p.id DESC)
            FROM page p), '[]'::json), 'next_cursor', CASE
    WHEN (SELECT count(*)
        FROM page) = ($8)::int THEN (SELECT (to_json(x.played_at) #>> '{}') || '|' || x.id::text
        FROM page x
        ORDER BY x.played_at ASC, x.id ASC
        LIMIT 1)
    END) AS body
