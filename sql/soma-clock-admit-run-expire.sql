UPDATE model_versions v
   SET status = 'rejected', reject_reason = 'TIMED_OUT',
       admit_started_at = NULL, admit_token = ($3)::uuid
 WHERE v.status = 'testing'
   AND (v.admit_started_at IS NULL
        OR v.admit_started_at < now() - (($2)::int * interval '1 second'))
   AND EXISTS (SELECT 1 FROM admissions a
                WHERE a.version_id = v.id AND a.report IS NULL AND a.attempts >= ($1)::int
                  AND (a.lease_expires_at IS NULL OR a.lease_expires_at < now()))
