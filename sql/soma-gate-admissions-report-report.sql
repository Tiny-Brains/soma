UPDATE admissions a
SET report = jsonb_build_object('admission', ($3)::jsonb, 'stats', ($4)::jsonb, 'probe', ($5)::jsonb),
reported_at = now(),
lease_expires_at = NULL
WHERE a.version_id = ($1)::uuid
AND a.claim_token = ($2)::uuid
AND a.runner_id = ($6)::uuid
AND a.report IS NULL
AND EXISTS (SELECT 1
    FROM live_runners lr
    WHERE lr.id = ($6)::uuid)
AND EXISTS (SELECT 1
    FROM model_versions v
    WHERE v.id = a.version_id
    AND v.status = 'testing')
