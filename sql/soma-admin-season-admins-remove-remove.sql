-- Remove a season admin by handle. A soft remove (removed_at set): the membership can be re-added,
-- and R3 ends any runner key the removed admin holds for this season at its next call. One audit line.
WITH se AS (
    SELECT s.id, s.slug FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text AND s.slug = ($2)::text ),
upd AS (
    UPDATE season_admins sa
       SET removed_at = now()
      FROM se, users u
     WHERE sa.season_id = se.id AND sa.user_id = u.id
       AND lower(u.handle) = lower(($3)::text) AND sa.removed_at IS NULL
    RETURNING sa.id, sa.user_id )
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season_admin.remove', 'season', (SELECT slug FROM se),
       jsonb_build_object('handle', ($3)::text, 'user_id', upd.user_id)
FROM upd
