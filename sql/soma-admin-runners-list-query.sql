-- EVERY RUNNER, the platform's and every season's. `live` is live_runners' own answer -- the
-- runner, its key and the key's owner in good standing, a season admin of its season counting for a
-- season key -- so the page never calls a working season runner dead. `season` is the slug a season
-- key is bound to, null for the platform fleet.
--
-- `plays_matches` and `admits` are the two roles, each reported at a token exchange and neither the
-- other's negation: a machine that has said neither is one from before either was reported, and the
-- page says so rather than guessing. Whether a QUEUE has an admitter is not this page's answer --
-- it spans the fleet policy of every live season -- and lives on /v1/status (`admitters`) and on
-- each season's own desk.
SELECT coalesce(json_agg(json_build_object('id', r.id, 'label', r.label, 'key_id', r.key_id, 'key_label',
                k.label, 'key_prefix', k.key_prefix, 'owner', u.handle, 'season', se.slug,
                'engine_digest', r.engine_digest,
                'node_version', r.node_version, 'orion_version', r.orion_version, 'ops_budget', r.ops_budget,
                'arch', r.arch, 'max_in_flight', r.max_in_flight, 'match_timeout_ms', r.match_timeout_ms,
                'seat_concurrency', r.seat_concurrency, 'plays_matches', r.plays_matches,
                'admits', r.admits,
                'first_seen_at', r.first_seen_at,
                'last_seen_at', r.last_seen_at, 'revoked_at', r.revoked_at,
                'live', EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = r.id),
                'in_flight', (SELECT count(*)
                FROM matches m
                WHERE m.played_by = r.id
                AND m.status IN ('claimed', 'running')), 'played', (SELECT count(*)
                FROM matches m
                WHERE m.played_by = r.id
                AND m.status IN ('finished', 'rated')))
        ORDER BY r.last_seen_at DESC), '[]'::json) AS body
FROM runners r
JOIN runner_keys k ON k.id = r.key_id
JOIN users u ON u.id = k.user_id
LEFT JOIN seasons se ON se.id = k.season_id
