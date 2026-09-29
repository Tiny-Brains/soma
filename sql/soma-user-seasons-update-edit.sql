-- EDIT A SCHEDULED SEASON, a season admin's or a platform admin's, and only before it opens: rules
-- and weight classes freeze at `submissions_open_at`, so `now() < s.submissions_open_at` is what
-- stops a live season's terms moving under the entries already rated by them.
--
-- EVERY SHAPE THE TABLE CHECKS IS CHECKED HERE TOO, in the WHERE, the way `season_fill_ok` is in
-- soma-admin-seasons-fill-set and `season_fleet_ok` in -fleet-set. Without them a malformed body
-- reached the CHECK constraints instead: 23514 made `db_write` a task error, so the route answered
-- 500 rather than the 422 its `diagnose` step exists to give, and the `audit_log` line -- a CTE of
-- this same statement -- rolled back with it, leaving a refused edit with no record. A rules block
-- with no `enabled`, or a window whose close is not after its open, are both ordinary competitor-
-- side mistakes, and this route is a SEASON admin's, not only a platform admin's.
--
-- The window pair is compared AFTER the coalesce, because either may be absent: an edit that moves
-- only the close must still land after the open the season already has.
WITH edited AS (UPDATE seasons s
SET submissions_open_at = coalesce(($3)::timestamptz, s.submissions_open_at),
submissions_close_at = coalesce(($4)::timestamptz, s.submissions_close_at),
rules = coalesce(($5)::jsonb, s.rules),
weight_classes = coalesce(($6)::jsonb, s.weight_classes)
FROM games g
WHERE g.id = s.game_id
AND g.slug = ($1)::text
AND s.slug = ($2)::text
AND s.closed_at IS NULL
AND now() < s.submissions_open_at
AND (($5)::jsonb IS NULL OR season_rules_ok(($5)::jsonb))
AND (($6)::jsonb IS NULL OR weight_classes_ok(($6)::jsonb))
AND coalesce(($4)::timestamptz, s.submissions_close_at)
  > coalesce(($3)::timestamptz, s.submissions_open_at)
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($7)::uuid, 'season.update', 'season', edited.slug, jsonb_strip_nulls(jsonb_build_object('game', ($1)::text,
            'submissions_open_at', ($3)::timestamptz, 'submissions_close_at', ($4)::timestamptz, 'rules',
            ($5)::jsonb, 'weight_classes', ($6)::jsonb))
FROM edited
