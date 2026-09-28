-- ONE SEASON'S RUNNER KEYS AND THEIR RUNNERS, for its season admins and platform admins: every key
-- bound to the season, newest first, whoever minted it, each with the runners started from it.
-- A runner's `live` is live_runners' own answer. The platform fleet is not listed: it is the
-- platform's, on the Runners page.
SELECT coalesce(json_agg(json_build_object(
         'id', k.id, 'label', k.label, 'key_prefix', k.key_prefix, 'owner', u.handle,
         'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
         'runners', (SELECT coalesce(json_agg(json_build_object(
                         'id', r.id, 'label', r.label, 'engine_digest', r.engine_digest,
                         'orion_version', r.orion_version, 'arch', r.arch,
                         'max_in_flight', r.max_in_flight, 'plays_matches', r.plays_matches,
                         'first_seen_at', r.first_seen_at, 'last_seen_at', r.last_seen_at,
                         'revoked_at', r.revoked_at,
                         'live', EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = r.id),
                         'in_flight', (SELECT count(*) FROM matches m
                                        WHERE m.played_by = r.id AND m.status IN ('claimed', 'running')),
                         'played', (SELECT count(*) FROM matches m
                                     WHERE m.played_by = r.id AND m.status IN ('finished', 'rated')))
                         ORDER BY r.last_seen_at DESC), '[]'::json)
                       FROM runners r WHERE r.key_id = k.id))
         ORDER BY k.created_at DESC), '[]'::json) AS body
  FROM runner_keys k
  JOIN users u ON u.id = k.user_id
 WHERE k.season_id = ($1)::uuid
