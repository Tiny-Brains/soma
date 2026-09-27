-- SET A SEASON'S FLEET POLICY (R4, N30). The fleet policy -- which runners play a season's matches
-- and admit its submissions, `own | platform | both` for each -- is a COLUMN, not a rule, precisely
-- so a PLATFORM admin can change it while the season is live: a university's own runners die mid-term
-- and the platform steps in, or a public season is handed to a cohort's spare capacity. Any time
-- before the season closes. season_fleet_ok() in the WHERE means a malformed policy writes nothing
-- rather than tripping the table CHECK, so `why` tells 422 (invalid) from 409 (closed) from 404. The
-- gate reads fleet live on every claim and admission claim, so nothing here is cached or epoch'd.
WITH updated AS (UPDATE seasons s
    SET fleet = ($3)::jsonb
    FROM games g
    WHERE g.id = s.game_id AND g.slug = ($1)::text AND s.slug = ($2)::text
    AND s.closed_at IS NULL
    AND season_fleet_ok(($3)::jsonb)
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season.fleet', 'season', updated.slug,
       jsonb_build_object('game', ($1)::text, 'fleet', ($3)::jsonb)
FROM updated
