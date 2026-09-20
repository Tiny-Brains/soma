WITH se AS (
    SELECT s.id, s.game_id
    FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text
    AND s.slug = ($2)::text
    AND s.closed_at IS NULL ),
nm AS (
    SELECT baseline_handle(($3)::text) AS handle, btrim(($3)::text) AS name ),
acct AS (
    INSERT INTO users (handle, role, display_name)
    SELECT nm.handle, 'baseline', nm.name
    FROM nm, se
    WHERE nm.handle IS NOT NULL
    ON CONFLICT (lower(handle)) DO NOTHING
    RETURNING id ),
who AS (
    SELECT id
    FROM acct
    UNION ALL
    SELECT u.id
    FROM users u, nm
    WHERE lower(u.handle) = lower(nm.handle)
    AND u.role = 'baseline' ),
ent AS (
    INSERT INTO models (owner_id, game_id, name)
    SELECT who.id, se.game_id, nm.name
    FROM who, se, nm
    WHERE NOT EXISTS (SELECT 1
        FROM models e
        WHERE e.owner_id = who.id
        AND e.game_id = se.game_id)
    ON CONFLICT DO NOTHING
    RETURNING id ),
entry AS (
    SELECT id
    FROM ent
    UNION ALL (SELECT e.id
        FROM models e, who, se
        WHERE e.owner_id = who.id
        AND e.game_id = se.game_id
        ORDER BY e.created_at
        LIMIT 1) ),
made AS (
    INSERT INTO model_versions (model_id, game_id, season_id, version, weights_hash, manifest_hash)
    SELECT entry.id, se.game_id, se.id, coalesce((SELECT max(x.version)
            FROM model_versions x
            WHERE x.model_id = entry.id), 0) + 1, ($4)::text, ($5)::text
    FROM entry, se
    WHERE ($4)::text ~ '^sha256:[0-9a-f]{64}$'
    AND ($5)::text ~ '^sha256:[0-9a-f]{64}$'
    AND NOT EXISTS (SELECT 1
        FROM model_versions x
        WHERE x.model_id = entry.id
        AND x.season_id = se.id
        AND x.status <> 'rejected')
    ON CONFLICT (model_id)
    WHERE status IN ('testing', 'verified') DO NOTHING
    RETURNING id )
INSERT INTO baseline_events (version_id, action, by_user)
SELECT made.id, 'upload', ($6)::uuid
FROM made
