-- THE SEASON ADMINS NAMED AT CREATE, assigned in the run that created the season: the check before
-- the create refused an unknown handle, so every name here is an account. The same row and audit
-- line soma-admin-season-admins-add writes; idempotent on the one-live index.
WITH se AS (
    SELECT s.id, s.slug FROM seasons s
      JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = season_slug(btrim(($2)::text))
), usr AS (
    SELECT DISTINCT u.id, u.handle
      FROM jsonb_array_elements_text(($3)::jsonb) h
      JOIN users u ON lower(u.handle) = lower(btrim(h)) AND u.role <> 'baseline'
), ins AS (
    INSERT INTO season_admins (season_id, user_id, added_by)
    SELECT se.id, usr.id, ($4)::uuid FROM se, usr
    ON CONFLICT (season_id, user_id) WHERE removed_at IS NULL DO NOTHING
    RETURNING user_id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season_admin.add', 'season', (SELECT slug FROM se),
       jsonb_build_object('game', ($1)::text,
                          'handle', (SELECT handle FROM usr WHERE usr.id = ins.user_id), 'user_id', ins.user_id)
  FROM ins
