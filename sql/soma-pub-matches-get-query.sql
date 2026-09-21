SELECT mt.replay_key, json_build_object( 'id', mt.id, 'game', g.slug, 'season', (SELECT se.slug
        FROM seasons se
        WHERE se.id = mt.season_id), 'status', mt.status, 'seed', mt.seed, 'map', (SELECT sm.map_id
        FROM season_maps sm
        WHERE sm.id = mt.season_map_id), 'reason', mt.reason, 'turns', mt.turns, 'played_ms', mt.played_ms,
        'played_at', mt.played_at, 'created_at', mt.created_at, 'withdrawn_reason', mt.withdrawn_reason,
        'successor_id', mt.successor_version_id, 'fault_reason', mt.fault_reason,
        'engine_digest', mt.engine_digest_played, 'orion_version', mt.orion_version, 'is_trial', mt.trial_version_id
        IS NOT NULL, 'ladders', array_to_json(mt.ladders), 'strike_limit', mt.strike_ceiling, 'successor',
        (SELECT json_build_object('version_id', sv.id, 'model_id', se2.id, 'model', se2.name, 'owner',
                su.handle, 'version', sv.version)
        FROM model_versions sv
        JOIN models se2 ON se2.id = sv.model_id
        JOIN users su ON su.id = se2.owner_id
        WHERE sv.id = mt.successor_version_id), 'players', (SELECT coalesce(json_agg(json_build_object(
                        'seat', s.seat, 'version_id', s.version_id, 'model_id', s.model_id, 'model',
                        s.model_name, 'owner', s.owner, 'baseline', s.baseline, 'class', s.class,
                        'model_version', s.version, 'outcome', s.outcome, 'rank', s.rank, 'score',
                        s.score, 'strikes', s.strikes, 'rating_change', (SELECT json_object_agg(e.ladder,
                            json_build_object( 'mu_before', e.mu_before, 'sigma_before', e.sigma_before,
                            'mu_after', e.mu_after, 'sigma_after', e.sigma_after))
                        FROM rating_events e
                        WHERE e.match_id = mt.id
                        AND e.seat = s.seat))
                ORDER BY s.seat), '[]'::json)
        FROM match_seat_rows(mt.id) s)) AS body
FROM matches mt
JOIN games g ON g.id = mt.game_id
WHERE mt.id = ($1)::uuid
