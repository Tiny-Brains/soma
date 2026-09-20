UPDATE matches
SET lease_expires_at = now() + ($2)::int * interval '1 second'
WHERE id = ($4)::uuid
AND claim_token = ($1)::uuid
AND status = 'running'
AND played_by = ($3)::uuid
AND EXISTS (SELECT 1
    FROM live_runners lr
    WHERE lr.id = ($3)::uuid)
