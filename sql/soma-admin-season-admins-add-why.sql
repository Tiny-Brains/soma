-- Why nothing was assigned: an unknown game/season, a closed one, an unknown handle, a baseline account, or the
-- account is already a live admin (which is a success, not a refusal).
SELECT json_build_object(
    'season', (SELECT s.slug FROM seasons s JOIN games g ON g.id = s.game_id
                WHERE g.slug = ($1)::text AND s.slug = ($2)::text),
    'closed', EXISTS (SELECT 1 FROM seasons s JOIN games g ON g.id = s.game_id
                       WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND s.closed_at IS NOT NULL),
    'user',   (SELECT json_build_object('id', u.id, 'baseline', u.role = 'baseline')
                 FROM users u WHERE lower(u.handle) = lower(($3)::text)),
    'already', EXISTS (SELECT 1 FROM season_admins sa
                        JOIN seasons s ON s.id = sa.season_id
                        JOIN games g   ON g.id = s.game_id
                        JOIN users u   ON u.id = sa.user_id
                        WHERE g.slug = ($1)::text AND s.slug = ($2)::text
                          AND lower(u.handle) = lower(($3)::text) AND sa.removed_at IS NULL)) AS body
