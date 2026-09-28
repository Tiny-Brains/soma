WITH asked AS (UPDATE seasons s
    SET close_requested_at = now()
    FROM games g
    WHERE g.id = s.game_id
    AND g.slug = ($1)::text
    AND s.slug = ($2)::text
    AND s.closed_at IS NULL
    AND s.close_requested_at IS NULL
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($3)::uuid, 'season.close', 'season', asked.slug, jsonb_build_object('game', ($1)::text)
FROM asked
