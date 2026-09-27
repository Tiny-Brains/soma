-- REMOVE ONE (N30), by the participant row's id ($2), within the season the fragment resolved ($1).
-- A soft remove (removed_at set), never a delete: the row is the record that they were a participant,
-- and the one-live partial index lets the same login be added again later as a fresh row. Removing a
-- participant stops further submissions at once (season_admits reads removed_at IS NULL) and, for a
-- private season, their view; a version already on the ladder stays (Q3). One audit line per removal.
WITH upd AS (
    UPDATE season_participants
       SET removed_at = now()
     WHERE id = ($2)::uuid AND season_id = ($1)::uuid AND removed_at IS NULL
    RETURNING id, provider, login
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'participant.remove', 'season', (SELECT slug FROM seasons WHERE id = ($1)::uuid),
       jsonb_build_object('provider', upd.provider, 'login', upd.login)
FROM upd
