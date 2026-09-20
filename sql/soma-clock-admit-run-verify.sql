UPDATE model_versions
   SET status = CASE WHEN EXISTS (SELECT 1 FROM models e JOIN users u ON u.id = e.owner_id
                                   WHERE e.id = model_versions.model_id AND u.role = 'baseline')
                     THEN 'disabled'::model_status ELSE 'verified'::model_status END,
       weight_class = ($2)::ladder,
       size_bytes = ($3)::bigint, param_count = ($4)::bigint,
       infer_us = ($5)::float8::bigint,
       manifest = (SELECT a.manifest FROM admissions a WHERE a.version_id = model_versions.id),
       orion_version = ($6)::text,
       probe_dims = ($8)::jsonb,
       admit_started_at = NULL, reject_reason = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($7)::uuid
   AND EXISTS (SELECT 1 FROM admissions a WHERE a.version_id = model_versions.id)
