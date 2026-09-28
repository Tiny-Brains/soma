-- The wrong-engine alert, over the seasons THIS runner's key reaches (N30): a season key against its
-- own season, a platform key against every live season. It goes to the key's owner, in the category
-- that owner reads: `admin` for a platform admin (linking the runners page), `season` for a season
-- admin's season key (linking their season's desk) -- `admin` is a platform admin's alone, so a
-- season admin would never have been told.
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, data, dedupe_key)
SELECT k.user_id, CASE WHEN o.role = 'admin' THEN 'admin' ELSE 'season' END, 'alert', 'warn',
    'Runner ' || left(r.label, 64) || ' is on an engine no season it serves plays',
    'It reports ' || left(r.engine_digest, 23) || '..., so it will claim nothing until it runs the engine its season pins.',
    CASE WHEN o.role = 'admin' THEN '/admin/runners'
         ELSE '/season-admin?season=' || (SELECT s.slug FROM seasons s WHERE s.id = k.season_id) END,
    jsonb_build_object('runner_id', r.id, 'label', r.label, 'engine_digest', r.engine_digest,
        'season_engine_digests', (SELECT jsonb_agg(DISTINCT s.engine_digest)
        FROM seasons s
        WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id))), 'runner-engine:' || r.id || ':' || r.engine_digest
FROM runners r
JOIN runner_keys k ON k.id = r.key_id
JOIN users o ON o.id = k.user_id
WHERE r.id = ($1)::uuid
AND r.engine_digest IS NOT NULL
AND EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id))
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.closed_at IS NULL AND (k.season_id IS NULL OR s.id = k.season_id)
    AND s.engine_digest = r.engine_digest)
AND notification_wanted(k.user_id, CASE WHEN o.role = 'admin' THEN 'admin' ELSE 'season' END)
ON CONFLICT (user_id, dedupe_key) DO NOTHING
