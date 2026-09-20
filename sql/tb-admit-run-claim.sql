UPDATE model_versions m
   SET admit_started_at = now(), admit_token = ($1)::uuid
 WHERE m.id IN (SELECT c.id FROM model_versions c
                 WHERE c.status = 'testing'
                   AND (c.admit_started_at IS NULL
                        OR c.admit_started_at < now() - (($3)::int * interval '1 second'))
                   AND NOT EXISTS (SELECT 1 FROM admissions a
                                    WHERE a.version_id = c.id AND a.report IS NULL)
                 ORDER BY c.created_at
                 LIMIT ($2)::int
                 FOR UPDATE SKIP LOCKED)
