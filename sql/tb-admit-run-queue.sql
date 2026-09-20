INSERT INTO admissions (version_id, registration, manifest, artifact_bytes, budget_ops)
SELECT v.id, ($2)::jsonb, ($3)::text, ($4)::bigint, ($5)::bigint
  FROM model_versions v
 WHERE v.id = ($1)::uuid AND v.status = 'testing' AND v.admit_token = ($6)::uuid
ON CONFLICT (version_id) DO NOTHING
