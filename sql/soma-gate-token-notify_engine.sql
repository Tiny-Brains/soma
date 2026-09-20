INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, data, dedupe_key)
SELECT k.user_id, 'admin', 'alert', 'warn', 'Runner ' || left(r.label, 64) || ' is on an engine no live season plays',
    'It reports ' || left(r.engine_digest, 23) || '..., so it will claim nothing until it runs the engine the live season pins.',
    '/admin/runners', jsonb_build_object('runner_id', r.id, 'label', r.label, 'engine_digest', r.engine_digest,
        'season_engine_digests', (SELECT jsonb_agg(DISTINCT s.engine_digest)
        FROM seasons s
        WHERE s.closed_at IS NULL)), 'runner-engine:' || r.id || ':' || r.engine_digest
FROM runners r
JOIN runner_keys k ON k.id = r.key_id
WHERE r.id = ($1)::uuid
AND r.engine_digest IS NOT NULL
AND EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL)
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL
    AND s.engine_digest = r.engine_digest)
AND notification_wanted(k.user_id, 'admin')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
