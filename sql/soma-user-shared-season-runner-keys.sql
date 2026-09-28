-- ONE SEASON'S RUNNER KEYS AND THEIR RUNNERS, for its season admins and platform admins: every key
-- bound to the season, newest first, whoever minted it, each with the runners started from it.
-- A runner's `live` is live_runners' own answer. The platform fleet is not listed: it is the
-- platform's, on the Runners page.
--
-- `admissions` IS THE SEASON'S OWN ANSWER TO "IS ANYTHING ADMITTING?", and it is why this route
-- returns an object rather than the bare list it used to. Nothing is admitted while no admitting
-- runner is up; a queued admission spends no attempt waiting, so the submission sits in `testing`
-- (phase `queued`) and expires with nothing anywhere naming the reason. A season whose
-- `fleet.admissions` is `own` has only its own machines to keep up, and the desk that mints its
-- keys is where an admin can act on it. `admitters_up(season)` is the admission claim's own reach
-- predicate, so the number cannot disagree with what would actually be claimed; `reach` says which
-- fleets those would be drawn from, because "start a machine" and "ask the platform to take it" are
-- different answers.
SELECT json_build_object(
  'admissions', json_build_object(
    'queued',    (SELECT count(*) FROM model_versions v
                   WHERE v.season_id = ($1)::uuid AND v.status = 'testing'),
    'admitters', admitters_up(($1)::uuid),
    'reach',     (SELECT se.fleet ->> 'admissions' FROM seasons se WHERE se.id = ($1)::uuid)),
  'keys', (SELECT coalesce(json_agg(json_build_object(
         'id', k.id, 'label', k.label, 'key_prefix', k.key_prefix, 'owner', u.handle,
         'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
         'runners', (SELECT coalesce(json_agg(json_build_object(
                         'id', r.id, 'label', r.label, 'engine_digest', r.engine_digest,
                         'orion_version', r.orion_version, 'arch', r.arch,
                         'max_in_flight', r.max_in_flight, 'plays_matches', r.plays_matches,
                         'admits', r.admits,
                         'first_seen_at', r.first_seen_at, 'last_seen_at', r.last_seen_at,
                         'revoked_at', r.revoked_at,
                         'live', EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = r.id),
                         'in_flight', (SELECT count(*) FROM matches m
                                        WHERE m.played_by = r.id AND m.status IN ('claimed', 'running')),
                         'played', (SELECT count(*) FROM matches m
                                     WHERE m.played_by = r.id AND m.status IN ('finished', 'rated')))
                         ORDER BY r.last_seen_at DESC), '[]'::json)
                       FROM runners r WHERE r.key_id = k.id))
         ORDER BY k.created_at DESC), '[]'::json)
       FROM runner_keys k
       JOIN users u ON u.id = k.user_id
      WHERE k.season_id = ($1)::uuid)) AS body
