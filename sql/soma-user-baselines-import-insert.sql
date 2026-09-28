-- IMPORT BASELINES FROM ANOTHER SEASON (Q7): every admitted baseline of the season `from` ($3) --
-- in play or switched off there, or those `baselines` (slugs) names -- becomes a version of the
-- same baseline account and entry in this live season, over the SAME BYTES (bytes_of: nothing is
-- uploaded or copied), `testing`. The admit clock admits it again under this season's classes,
-- memory and engine, and it lands `disabled` like any baseline upload, for an admin to switch on.
-- A baseline this season already holds a version of is left as it is. The source must be a season
-- the caller may see. An audit line and a baseline_events `upload` each. $4 is the whole request, as
-- in soma-user-maps-import-insert.sql, so a `baselines` that is not an array imports nothing.
WITH tgt AS (
    SELECT s.id FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND s.closed_at IS NULL
), src AS (
    SELECT s.id FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = ($3)::text AND season_visible(s, ($5)::uuid)
       AND s.slug <> ($2)::text
), pick AS (
    SELECT DISTINCT ON (v.model_id)
           v.model_id, v.game_id, coalesce(v.bytes_of, v.id) AS bytes, v.weights_hash, v.manifest_hash,
           u.handle
      FROM src
      JOIN model_versions v ON v.season_id = src.id AND v.status IN ('active', 'disabled')
      JOIN models e ON e.id = v.model_id
      JOIN users u  ON u.id = e.owner_id AND u.role = 'baseline'
     WHERE coalesce(jsonb_typeof(($4)::jsonb -> 'baselines'), 'null') = 'null'
        OR substr(u.handle, length('baseline.') + 1) IN (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(($4)::jsonb -> 'baselines') = 'array'
                                              THEN ($4)::jsonb -> 'baselines' ELSE '[]'::jsonb END))
     ORDER BY v.model_id, v.version DESC
), made AS (
    INSERT INTO model_versions (model_id, game_id, season_id, version, weights_hash, manifest_hash, bytes_of)
    SELECT p.model_id, p.game_id, tgt.id,
           (SELECT coalesce(max(x.version), 0) + 1 FROM model_versions x WHERE x.model_id = p.model_id),
           p.weights_hash, p.manifest_hash, p.bytes
      FROM pick p, tgt
     WHERE NOT EXISTS (SELECT 1 FROM model_versions x
                        WHERE x.model_id = p.model_id AND x.season_id = tgt.id AND x.status <> 'rejected')
    ON CONFLICT (model_id, season_id) WHERE status IN ('testing', 'verified') DO NOTHING
 RETURNING id, model_id
), audit AS (
    INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
    SELECT ($5)::uuid, 'baseline.import', 'baseline', p.handle,
           jsonb_build_object('game', ($1)::text, 'season', ($2)::text, 'from', ($3)::text, 'version_id', made.id)
      FROM made JOIN pick p ON p.model_id = made.model_id
)
INSERT INTO baseline_events (version_id, action, by_user)
SELECT made.id, 'upload', ($5)::uuid
  FROM made
