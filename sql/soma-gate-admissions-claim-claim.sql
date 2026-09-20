WITH pick AS MATERIALIZED (
    SELECT a.version_id
    FROM admissions a
    JOIN model_versions v ON v.id = a.version_id
    AND v.status = 'testing'
    WHERE a.report IS NULL
    AND (a.lease_expires_at IS NULL
        OR a.lease_expires_at < now())
    AND a.attempts < ($4)::int
    AND EXISTS (SELECT 1
        FROM live_runners lr
        WHERE lr.id = ($1)::uuid)
    ORDER BY a.prepared_at, a.version_id
    LIMIT 1
    FOR UPDATE OF a SKIP LOCKED)
UPDATE admissions a
SET runner_id = ($1)::uuid, claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval
    '1 second', attempts = a.attempts + 1
FROM pick
WHERE a.version_id = pick.version_id
