WITH pick AS MATERIALIZED (SELECT m.id
    FROM matches m
    WHERE m.status = 'pending'
    AND m.engine_digest = ($1)::text
    AND m.seat_count <= ($4)::int
    AND EXISTS (SELECT 1
        FROM live_runners lr
        WHERE lr.id = ($5)::uuid
        AND (SELECT count(*)
            FROM matches h
            WHERE h.played_by = ($5)::uuid
            AND h.status IN ('claimed', 'running')) < lr.max_in_flight)
    ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.refusals, m.created_at, m.id
    LIMIT 1
    FOR UPDATE SKIP LOCKED)
UPDATE matches m
SET status = 'claimed', claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval
    '1 second', played_by = ($5)::uuid
FROM pick
WHERE m.id = pick.id
