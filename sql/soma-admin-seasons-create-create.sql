WITH game AS (
    SELECT g.id, g.active_engine_digest
    FROM games g
    WHERE g.slug = ($1)::text ),
last AS (
    SELECT max(s.number) AS number
    FROM seasons s
    JOIN game ON game.id = s.game_id ),
created AS (INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at,
        rules, weight_classes, visibility, entry, fleet, providers)
SELECT game.id, coalesce(last.number, 0) + 1, btrim(($6)::text),
season_slug(btrim(($6)::text)),
game.active_engine_digest, ($2)::timestamptz, ($3)::timestamptz, coalesce(($4)::jsonb, '{}'::jsonb),
coalesce(($5)::jsonb, (SELECT s.weight_classes
        FROM seasons s
        WHERE s.game_id = game.id
        ORDER BY s.number DESC
        LIMIT 1), default_weight_classes()),
coalesce(($8)::text, 'public'),
-- Private forces restricted whatever the body said, so the pair can never disagree with the CHECK.
CASE WHEN coalesce(($8)::text, 'public') = 'private' THEN 'restricted'
     ELSE coalesce(($9)::text, 'open') END,
coalesce(($10)::jsonb, '{"matches":"platform","admissions":"platform"}'::jsonb),
($11)::jsonb
FROM game, last
WHERE game.active_engine_digest IS NOT NULL
AND char_length(btrim(($6)::text)) BETWEEN 1
AND 48
AND season_slug(btrim(($6)::text)) ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
AND char_length(season_slug(btrim(($6)::text))) <= 48
AND season_slug(btrim(($6)::text)) NOT IN ('current', 'live', 'latest', 'new')
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.game_id = game.id
    AND s.slug = season_slug(btrim(($6)::text)))
    RETURNING id, slug, name)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($7)::uuid, 'season.create', 'season', created.slug, jsonb_build_object('game', ($1)::text, 'name',
        created.name)
FROM created
