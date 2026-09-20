UPDATE seasons s
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
