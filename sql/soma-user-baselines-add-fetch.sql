-- WHAT IS LEFT OF THE WINDOW, not a fresh one. The admit clock gives a version upload_window_s from
-- created_at to arrive, so a re-mint's URLs expire when that does: a URL good past it is an upload
-- the clock has already given up on. The minutes round down, so the response never promises time
-- the version does not have.
SELECT season_baseline_json(v) AS body, w.s AS upload_s, CASE
    WHEN w.s >= 60 THEN (w.s / 60) || 'm'
    ELSE w.s || 's'
    END AS upload_expires_in
FROM model_versions v
CROSS JOIN LATERAL (SELECT greatest(1, ($6)::int - floor(extract(epoch FROM now() - v.created_at))::int) AS s) w
JOIN models e ON e.id = v.model_id
JOIN users u ON u.id = e.owner_id
AND u.role = 'baseline'
JOIN seasons se ON se.id = v.season_id
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text
AND se.slug = ($2)::text
AND lower(u.handle) = lower(baseline_handle(($3)::text))
AND v.status = 'testing'
AND v.weights_hash = ($4)::text
AND v.manifest_hash = ($5)::text
ORDER BY v.created_at DESC
LIMIT 1
