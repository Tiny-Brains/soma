-- A season's live admins, by handle. Readable by the season's own admins and platform admins (the
-- season-admin-only fragment gates the route). Keyed on game+slug so the add/remove routes, which run
-- under admin-only and have no resolved season id in hand, can read the same statement back.
SELECT json_build_object(
    'season', se.slug,
    'admins', coalesce((SELECT json_agg(json_build_object(
                'id',           sa.id,
                'user_id',      sa.user_id,
                'handle',       u.handle,
                'display_name', u.display_name,
                'added_at',     sa.added_at)
            ORDER BY lower(u.handle))
        FROM season_admins sa
        JOIN users u ON u.id = sa.user_id
        WHERE sa.season_id = se.id AND sa.removed_at IS NULL), '[]'::json)) AS body
FROM seasons se
JOIN games g ON g.id = se.game_id
WHERE g.slug = ($1)::text AND se.slug = ($2)::text
