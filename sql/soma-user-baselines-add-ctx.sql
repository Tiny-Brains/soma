-- What a baseline upload is judged against: the season, the name's account, what the name already
-- holds in this season, and whether the caller may use the name at all.
WITH se AS (
    SELECT s.id, s.closed_at
    FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text
    AND s.slug = ($2)::text ),
nm AS (
    SELECT baseline_handle(($3)::text) AS handle )
SELECT json_build_object( 'season', EXISTS (SELECT 1
        FROM se),
        -- A BASELINE NAME ANOTHER SEASON ALREADY USES is a platform name: the account, its profile and
        -- its record are shared across seasons, so only a platform admin ($7 = 'platform') may add a
        -- version to it. A season admin names their own baselines.
        'reserved', coalesce(($7)::text, '') <> 'platform' AND EXISTS (SELECT 1
            FROM users u
            JOIN models e ON e.owner_id = u.id
            JOIN model_versions v ON v.model_id = e.id
            WHERE lower(u.handle) = lower(nm.handle) AND u.role = 'baseline'
            AND v.season_id NOT IN (SELECT id FROM se)), 'closed', (SELECT se.closed_at IS NOT NULL
        FROM se), 'handle', nm.handle, 'hashes_ok', coalesce(($4)::text ~ '^sha256:[0-9a-f]{64}$'
        AND ($5)::text ~ '^sha256:[0-9a-f]{64}$', false), 'existing', (SELECT json_build_object( 'slug',
                substr(u.handle, length('baseline.') + 1), 'name', e.name, 'status', v.status, 'enabled',
                v.status = 'active', 'same', v.status = 'testing'
            AND v.weights_hash = ($4)::text
            AND v.manifest_hash = ($5)::text
            AND v.created_at > now() - (($6)::int * interval '1 second'))
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
