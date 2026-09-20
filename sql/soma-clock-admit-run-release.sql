UPDATE model_versions
   SET admit_started_at = NULL, admit_token = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($2)::uuid
