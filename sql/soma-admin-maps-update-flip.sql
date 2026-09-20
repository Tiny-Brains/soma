WITH target AS (
    SELECT sm.id
    FROM season_maps sm
    JOIN seasons se ON se.id = sm.season_id
    JOIN games g ON g.id = se.game_id
    WHERE g.slug = ($1)::text
    AND se.slug = ($2)::text
    AND sm.map_id = ($3)::text
    AND se.closed_at IS NULL
    AND sm.enabled IS DISTINCT
    FROM ($4)::boolean
    FOR UPDATE OF sm ),
flipped AS (
    UPDATE season_maps sm
    SET enabled = ($4)::boolean
    FROM target
    WHERE sm.id = target.id
    RETURNING sm.id ),
cancelled AS (
    UPDATE matches m
    SET status = 'cancelled', withdrawn_reason = 'MAP_DISABLED', closed_at = now()
    FROM flipped
    WHERE NOT ($4)::boolean
    AND m.season_map_id = flipped.id
    AND m.status = 'pending'
    RETURNING m.id )
INSERT INTO season_map_events (season_map_id, enabled, by_user, cancelled)
SELECT flipped.id, ($4)::boolean, ($5)::uuid, (SELECT count(*)
    FROM cancelled)
FROM flipped
