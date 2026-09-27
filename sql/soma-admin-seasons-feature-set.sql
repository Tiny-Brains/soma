-- MAKE THIS SEASON THE GAME'S FEATURED ONE (S4, N30). The featured season is what current_season()
-- and web's "no season" read resolve to; a private season is NEVER featured (S4), so the UPDATE
-- gates on visibility = 'public' and a private slug writes nothing -- the workflow's `why` then tells
-- 404 (no such season) from 422 (it exists but is private). Re-featuring the same season is a
-- no-op UPDATE that still records the intent. games.featured_season_id is ON DELETE SET NULL, so a
-- deleted season clears it. Setting it moves what every "no season" public read resolves to, so the
-- caller invalidates season + ladder after this writes.
WITH featured AS (UPDATE games g
    SET featured_season_id = s.id
    FROM seasons s
    WHERE g.slug = ($1)::text
    AND s.game_id = g.id
    AND s.slug = ($2)::text
    AND s.visibility = 'public'
    RETURNING g.slug AS game, s.slug AS season)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'season.feature', 'season', featured.season, jsonb_build_object('game', featured.game)
FROM featured
