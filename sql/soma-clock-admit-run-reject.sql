UPDATE model_versions
   SET status = 'rejected', reject_reason = ($2)::text,
       admit_started_at = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($3)::uuid
