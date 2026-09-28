-- SET A SEASON'S IDLE FILL (seasons.fill), a platform admin's, any time before the season closes:
-- it is capacity, like the fleet policy, and moves no rating's meaning. season_fill_ok() in the
-- WHERE means a malformed setting writes nothing rather than tripping the table CHECK, so `why`
-- tells 422 from 409 from 404. Pair reads it on its next tick; nothing is cached. Audited.
WITH updated AS (UPDATE seasons s
    SET fill = ($3)::jsonb
    FROM games g
    WHERE g.id = s.game_id AND g.slug = ($1)::text AND s.slug = ($2)::text
    AND s.closed_at IS NULL
    AND season_fill_ok(($3)::jsonb)
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season.fill', 'season', updated.slug,
       jsonb_build_object('game', ($1)::text, 'fill', ($3)::jsonb)
FROM updated
