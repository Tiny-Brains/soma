-- A SEASON ADMIN (or a platform admin) REVOKES ONE OF THIS SEASON'S KEYS, whoever minted it. A key
-- of another season, or of the platform fleet, is out of reach: the season id comes from the
-- season-admin-only fragment, and nothing matches outside it. Audited.
WITH revoked AS (
    UPDATE runner_keys k SET revoked_at = now()
     WHERE k.id = try_uuid(($1)::text) AND k.season_id = ($2)::uuid AND k.revoked_at IS NULL
 RETURNING k.id, k.label, k.key_prefix
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'runner_key.revoke', 'runner_key', revoked.id::text,
       jsonb_build_object('label', revoked.label, 'prefix', revoked.key_prefix,
                          'game', ($5)::text, 'season', ($4)::text)
  FROM revoked
