WITH game AS (
    SELECT g.id, g.active_engine_digest
    FROM games g
    WHERE g.slug = ($1)::text ),
last AS (
    SELECT max(s.number) AS number, max(s.closed_at) AS closed_at
    FROM seasons s
    JOIN game ON game.id = s.game_id )
INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at,
        rules, weight_classes)
SELECT game.id, coalesce(last.number, 0) + 1, btrim(($7)::text),
season_slug(btrim(($7)::text)),
game.active_engine_digest, ($2)::timestamptz, ($3)::timestamptz, coalesce(($5)::jsonb, '{}'::jsonb),
coalesce(($6)::jsonb, (SELECT s.weight_classes
        FROM seasons s
        WHERE s.game_id = game.id
        ORDER BY s.number DESC
        LIMIT 1), default_weight_classes())
FROM game, last
WHERE game.active_engine_digest IS NOT NULL
AND char_length(btrim(($7)::text)) BETWEEN 1
AND 48
AND season_slug(btrim(($7)::text)) ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
AND char_length(season_slug(btrim(($7)::text))) <= 48
AND season_slug(btrim(($7)::text)) NOT IN ('current', 'live', 'latest', 'new')
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.game_id = game.id
    AND s.slug = season_slug(btrim(($7)::text)))
AND NOT EXISTS (SELECT 1
    FROM seasons s
    WHERE s.game_id = game.id
    AND s.closed_at IS NULL)
AND ($2)::timestamptz >= coalesce(last.closed_at, '-infinity'::timestamptz) + make_interval(days =>
        ($4)::int)
