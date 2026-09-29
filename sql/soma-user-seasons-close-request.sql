WITH asked AS (UPDATE seasons s
    SET close_requested_at = now()
    FROM games g
    WHERE g.id = s.game_id
    AND g.slug = ($1)::text
    AND s.slug = ($2)::text
    AND s.closed_at IS NULL
    AND s.close_requested_at IS NULL
    -- ONLY A SEASON THAT HAS OPENED, which is what the route's own 409 already promises ("Only the
    -- live season can be asked to close"). Without it a SCHEDULED season could be asked, and the
    -- withdraw clock takes `close_requested_at IS NOT NULL` as its top-priority branch, ahead of
    -- every settled and finals test -- so within the minute a season nobody had entered was closed
    -- on an empty frozen podium. There is no un-close route, `soma-user-seasons-update-edit`
    -- requires `closed_at IS NULL`, and `seasons UNIQUE (game_id, slug)` with the CHECK-derived slug
    -- means the name can never be used again: one mis-click permanently burned the season.
    AND now() >= s.submissions_open_at
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'season.close', 'season', asked.slug, jsonb_build_object('game', ($1)::text)
FROM asked
