SELECT json_build_object('id', m.id, 'seed', m.seed, 'map_id', sm.map_id, 'map', sm.board, 'seat_count',
        m.seat_count, 'trial_model_id', m.trial_version_id, 'strike_ceiling', m.strike_ceiling, 'seats',
        (SELECT json_agg(json_build_object('m', 0, 'seat', s.seat, 'version_id', s.version_id, 'model',
                    ($2)::text || s.version_id::text, 'strike_ceiling', m.strike_ceiling, 'weights_hash',
                    s.weights_hash, 'manifest_hash', s.manifest_hash)
            ORDER BY s.seat)
        FROM match_seats s
        WHERE s.match_id = m.id)) AS row, m.engine_digest AS engine_digest, m.lease_expires_at AS
    lease_expires_at, json_build_object('turn_ms', e.turn_ms, 'max_turns', e.max_turns, 'model_prefix',
        ($2)::text, 'engine_digest', m.engine_digest, 'replay_prefix', ($3)::text, 'renew_every_n_turns',
        GREATEST(1, LEAST(($4)::int, (($5)::int * 1000) / ((m.seat_count + 1) * e.turn_ms))), 'lease_seconds',
        ($5)::int, 'refusal_ceiling', e.refusal_ceiling) AS contract
FROM matches m
JOIN season_maps sm ON sm.id = m.season_map_id
JOIN seasons se ON se.id = m.season_id
JOIN games g ON g.id = m.game_id
CROSS JOIN LATERAL (SELECT coalesce(CASE
        WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'turn_ms')::int
        END, (g.manifest -> 'limits' ->> 'turn_ms')::int, ($6)::int) AS turn_ms, coalesce(CASE
        WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'max_turns')::int
        END, (g.manifest -> 'limits' ->> 'max_turns')::int, ($7)::int) AS max_turns, coalesce(CASE
        WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'refusal_ceiling')::int
        END, ($8)::int) AS refusal_ceiling) e
WHERE m.claim_token = ($1)::uuid
AND m.status = 'claimed'
