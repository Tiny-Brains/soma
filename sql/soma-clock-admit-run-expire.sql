-- A SLOW PROBE ON EVERY ATTEMPT IS THE MODEL'S, and anything else that runs out is TIMED_OUT: a
-- probe over models.max_probe_ms goes back to the queue once per runner that measured it, because
-- one machine's load is not the model's fault, but every machine that tried agreeing is.
UPDATE model_versions v
   SET status = 'rejected',
       reject_reason = CASE WHEN a.slow_probes >= a.attempts THEN 'PROBE_TOO_SLOW'
                            ELSE 'TIMED_OUT' END,
       admit_started_at = NULL, admit_token = ($3)::uuid
  FROM admissions a
 WHERE v.status = 'testing'
   AND (v.admit_started_at IS NULL
        OR v.admit_started_at < now() - (($2)::int * interval '1 second'))
   AND a.version_id = v.id AND a.report IS NULL AND a.attempts >= ($1)::int
   AND (a.lease_expires_at IS NULL OR a.lease_expires_at < now())
