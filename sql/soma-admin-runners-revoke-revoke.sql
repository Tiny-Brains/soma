WITH revoked AS (UPDATE runners r
    SET revoked_at = now()
    WHERE r.id = ($1)::uuid
    AND r.revoked_at IS NULL
    RETURNING r.id, r.label)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($2)::uuid, 'runner.revoke', 'runner', revoked.id::text, jsonb_build_object('label', revoked.label)
FROM revoked
