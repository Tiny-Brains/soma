-- Assign a season admin by platform handle. A membership, not a role (user_role is untouched). A
-- baseline account cannot be one (A1), and a closed season takes none: its standings are final. Idempotent: already an admin is left as it is (ON CONFLICT on
-- the one-live index). One audit line when a row is actually written; the notification to the account
-- is a separate continue_on_error writer (deferred with the other new notification kinds).
WITH se AS (
    SELECT s.id, s.slug FROM seasons s
    JOIN games g ON g.id = s.game_id
    WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND s.closed_at IS NULL ),
usr AS (
    SELECT u.id FROM users u
    WHERE lower(u.handle) = lower(($3)::text) AND u.role <> 'baseline' ),
ins AS (
    INSERT INTO season_admins (season_id, user_id, added_by)
    SELECT se.id, usr.id, ($4)::uuid FROM se, usr
    ON CONFLICT (season_id, user_id) WHERE removed_at IS NULL DO NOTHING
    RETURNING id, user_id )
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season_admin.add', 'season', (SELECT slug FROM se),
       jsonb_build_object('handle', ($3)::text, 'user_id', ins.user_id)
FROM ins
