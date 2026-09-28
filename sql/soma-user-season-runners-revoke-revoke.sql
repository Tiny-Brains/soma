-- A SEASON ADMIN (or a platform admin) STOPS ONE RUNNER of this season's keys: its next call fails,
-- its current match does not. A runner on another season's key, or on the platform fleet, is out of
-- reach. Audited.
WITH revoked AS (
    UPDATE runners r SET revoked_at = now()
      FROM runner_keys k
     WHERE r.id = try_uuid(($1)::text) AND k.id = r.key_id AND k.season_id = ($2)::uuid
       AND r.revoked_at IS NULL
 RETURNING r.id, r.label
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'runner.revoke', 'runner', revoked.id::text,
       jsonb_build_object('label', revoked.label, 'season', ($4)::text)
  FROM revoked
