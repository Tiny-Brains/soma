UPDATE admissions a
   SET report = NULL, reported_at = NULL, claim_token = NULL, lease_expires_at = NULL,
       requeued_for = ($3)::text
 WHERE a.version_id = ($1)::uuid AND a.report IS NOT NULL
   AND EXISTS (SELECT 1 FROM model_versions v
                WHERE v.id = a.version_id AND v.status = 'testing' AND v.admit_token = ($2)::uuid)
