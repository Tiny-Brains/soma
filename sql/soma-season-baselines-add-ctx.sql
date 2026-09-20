WITH se AS (
    SELECT s.id, s.closed_at
    FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text
    AND s.slug = ($2)::text ),
nm AS (
    SELECT baseline_handle(($3)::text) AS handle )
SELECT json_build_object( 'season', EXISTS (SELECT 1
        FROM se), 'closed', (SELECT se.closed_at IS NOT NULL
        FROM se), 'handle', nm.handle, 'hashes_ok', coalesce(($4)::text ~ '^sha256:[0-9a-f]{64}$'
        AND ($5)::text ~ '^sha256:[0-9a-f]{64}$', false), 'existing', (SELECT json_build_object( 'slug',
                substr(u.handle, length('baseline.') + 1), 'name', e.name, 'status', v.status, 'enabled',
                v.status = 'active', 'same', v.status = 'testing'
            AND v.weights_hash = ($4)::text
            AND v.manifest_hash = ($5)::text)
        FROM model_versions v
        JOIN models e ON e.id = v.model_id
        JOIN users u ON u.id = e.owner_id
        AND u.role = 'baseline'
        JOIN se ON se.id = v.season_id
        WHERE lower(u.handle) = lower(nm.handle)
        AND v.status <> 'rejected'
        ORDER BY v.created_at DESC
        LIMIT 1)) AS body
FROM nm
