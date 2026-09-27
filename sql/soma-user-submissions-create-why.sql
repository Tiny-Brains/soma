-- WHY NOTHING WAS INSERTED. `session_ok` first: the insert joins live_sessions, so a dead session
-- writes nothing and would otherwise read as a season, model or note refusal. The season is the one
-- the submission named, or the game's featured public season when it named none (N30) --
-- current_season(g.id, <slug>), LEFT JOIN LATERAL so a row comes back even when it resolves nothing
-- (an unknown game or slug), which the revoked/unknown_model refusals ride.
WITH me AS (
    SELECT true AS live FROM live_sessions ls
     WHERE ls.sid = ($8)::uuid AND ls.user_id = ($2)::uuid
)
SELECT coalesce(me.live, false) AS session_ok, json_build_object( 'season', s.slug, 'note_word', text_hold_tag(($7)::text, false), 'state', CASE
    WHEN s.id IS NOT NULL THEN season_state(s)
    END, 'submissions_open_at', s.submissions_open_at, 'submissions_close_at', s.submissions_close_at,
        'model', (SELECT json_build_object('model_id', e.id, 'model', e.name, 'retired', e.retired_at
                IS NOT NULL)
        FROM models e
        WHERE e.game_id = g.id
        AND e.owner_id = ($2)::uuid
        AND e.id = ($4)::uuid), 'participant', s.id IS NULL
    OR season_admits(s, ($2)::uuid), 'entry_room', s.id IS NULL
    OR (SELECT season_admits_entry(s, ($2)::uuid, e.id)
        FROM models e
        WHERE e.game_id = g.id
        AND e.owner_id = ($2)::uuid
        AND e.id = ($4)::uuid), 'in_flight', coalesce((SELECT json_agg(json_build_object('version_id',
                        f.id, 'model_id', f.model_id, 'model', fe.name, 'version', f.version, 'phase',
                        model_phase(f))
                ORDER BY fe.name)
            FROM model_versions f
            JOIN models fe ON fe.id = f.model_id
            WHERE fe.owner_id = ($2)::uuid
            AND fe.game_id = g.id
            AND f.status IN ('testing', 'verified')), '[]'::json), 'same_submission', EXISTS (SELECT
            1
        FROM model_versions f
        JOIN models fe ON fe.id = f.model_id
        WHERE fe.game_id = g.id
        AND fe.owner_id = ($2)::uuid
        AND fe.id = ($4)::uuid
        AND f.season_id = s.id
        AND f.status = 'testing'
        AND f.weights_hash = ($3)::text
        AND f.manifest_hash = ($5)::text
        AND f.created_at > now() - (($6)::int * interval '1 second')), 'entry_in_flight', EXISTS (SELECT 1
        FROM model_versions f
        JOIN models fe ON fe.id = f.model_id
        WHERE fe.game_id = g.id
        AND fe.owner_id = ($2)::uuid
        AND fe.id = ($4)::uuid
        AND f.season_id = s.id
        AND f.status IN ('testing', 'verified')), 'in_flight_ok', s.id IS NULL
    OR season_admits_in_flight(s, ($2)::uuid), 'versions_ok', s.id IS NULL
    OR (SELECT season_admits_version(s, ($2)::uuid, e.id)
        FROM models e
        WHERE e.game_id = g.id
        AND e.owner_id = ($2)::uuid
        AND e.id = ($4)::uuid), 'cooldown_until', (SELECT season_cooldown_until(s, e.id)
        FROM models e
        WHERE e.game_id = g.id
        AND e.owner_id = ($2)::uuid
        AND e.id = ($4)::uuid), 'unique_weights_scope', coalesce(s.rules -> 'unique_weights' ->> 'scope',
            'game'), 'unique_weights', s.id IS NULL
    OR (SELECT season_admits_weights(s, ($2)::uuid, ($3)::text, e.id)
        FROM models e
        WHERE e.game_id = g.id
        AND e.owner_id = ($2)::uuid
        AND e.id = ($4)::uuid)) AS body
FROM games g
LEFT JOIN me ON true
LEFT JOIN current_season(g.id, nullif(($9)::text, '')) s ON true
WHERE g.slug = ($1)::text
