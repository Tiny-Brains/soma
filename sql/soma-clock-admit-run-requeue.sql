WITH back AS (
    UPDATE admissions a
       SET report = NULL, reported_at = NULL, claim_token = NULL, lease_expires_at = NULL,
           requeued_for = ($3)::text,
           slow_probes = a.slow_probes + CASE WHEN ($3)::text = 'PROBE_TOO_SLOW' THEN 1 ELSE 0 END
     WHERE a.version_id = ($1)::uuid AND a.report IS NOT NULL
       AND EXISTS (SELECT 1 FROM model_versions v
                    WHERE v.id = a.version_id AND v.status = 'testing' AND v.admit_token = ($2)::uuid)
 RETURNING a.version_id
)
-- A slow probe's median, kept where the version's timing is read. Only a measurement replaces it.
UPDATE model_versions v
   SET infer_us = coalesce(($4)::bigint, v.infer_us)
  FROM back
 WHERE v.id = back.version_id
