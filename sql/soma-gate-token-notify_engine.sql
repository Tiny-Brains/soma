-- The wrong-engine alert, over the seasons THIS runner's key reaches (N30): a season key against its
-- own season, a platform key against every live season. A season runner on the wrong digest alerts
-- its season admins (the key's owner); a platform runner alerts the platform admin who owns the key.
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, data, dedupe_key)
SELECT k.user_id, 'admin', 'alert', 'warn', 'Runner ' || left(r.label, 64) || ' is on an engine no season it serves plays',
    'It reports ' || left(r.engine_digest, 23) || '..., so it will claim nothing until it runs the engine its season pins.',
    '/admin/runners', jsonb_build_object('runner_id', r.id, 'label', r.label, 'engine_digest', r.engine_digest,
        'season_engine_digests', (SELECT jsonb_agg(DISTINCT s.engine_digest)
        FROM seasons s
        WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id))), 'runner-engine:' || r.id || ':' || r.engine_digest
FROM runners r
JOIN runner_keys k ON k.id = r.key_id
WHERE r.id = ($1)::uuid
AND r.engine_digest IS NOT NULL
AND EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id))
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id)
    AND s.engine_digest = r.engine_digest)
AND notification_wanted(k.user_id, 'admin')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
