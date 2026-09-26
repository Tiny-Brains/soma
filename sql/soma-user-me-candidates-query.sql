-- EVERY VERSION OF YOURS STILL IN FLIGHT, the field GET /v1/me used to carry. Its own route because
-- the admit clock changes it and cannot name the user in a bump, so it could never be cached with
-- the rest of /v1/me. live_sessions is the outer FROM: no row is a dead session (401), and a live
-- session with nothing in flight is a row carrying [].
SELECT true AS session_ok,
       coalesce((SELECT json_agg(json_build_object('version_id', v.id, 'model_id', e.id, 'model', e.name,
                                                   'game', g.slug, 'version', v.version, 'phase', model_phase(v))
                        ORDER BY g.slug, e.name)
                   FROM model_versions v
                   JOIN models e ON e.id = v.model_id
                   JOIN games g ON g.id = e.game_id
                  WHERE e.owner_id = u.id
                    AND v.status IN ('testing', 'verified')), '[]'::json) AS body
  FROM users u
  JOIN live_sessions s ON s.user_id = u.id AND s.sid = ($2)::uuid
 WHERE u.id = ($1)::uuid
