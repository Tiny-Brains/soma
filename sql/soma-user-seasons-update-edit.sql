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
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($7)::uuid, 'season.update', 'season', edited.slug, jsonb_strip_nulls(jsonb_build_object('game', ($1)::text,
            'submissions_open_at', ($3)::timestamptz, 'submissions_close_at', ($4)::timestamptz, 'rules',
            ($5)::jsonb, 'weight_classes', ($6)::jsonb))
FROM edited
