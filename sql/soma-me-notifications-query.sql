WITH me AS (
    SELECT ls.user_id
    FROM live_sessions ls
    WHERE ls.sid = ($2)::uuid
    AND ls.user_id = ($1)::uuid ),
lim AS (
    SELECT least(greatest(($7)::int, 1), 100) AS n ),
feed AS NOT MATERIALIZED (
    SELECT n.*
    FROM notifications n
    JOIN me ON n.user_id = me.user_id
    WHERE (($3)::text IS NULL
        OR n.category = ($3)::text)
    AND (($4)::text IS DISTINCT
        FROM 'true'
        OR n.read_at IS NULL)
    AND (($5)::timestamptz IS NULL
        OR n.created_at > ($5)::timestamptz) ),
page AS (
    SELECT *
    FROM feed
    WHERE ($6)::text IS NULL
    OR (created_at, id) < (split_part(($6)::text, '|', 1)::timestamptz, split_part(($6)::text, '|',
                2)::uuid)
    ORDER BY created_at DESC, id DESC
    LIMIT (SELECT n
        FROM lim) )
SELECT me.user_id AS session_ok, (($3)::text IS NULL
    OR notification_category_ok(($3)::text)) AS category_ok, (SELECT json_agg(sp.category
        ORDER BY sp.ord)
    FROM notification_category_spec() sp) AS categories, json_build_object( 'notifications', coalesce((SELECT
                json_agg(json_build_object( 'id', p.id, 'category', p.category, 'kind', p.kind, 'tone',
                        p.tone, 'icon', p.icon, 'subject', p.subject, 'description', p.description,
                        'link', p.link, 'game', p.game, 'season', p.season, 'model_id', p.model_id,
                        'version_id', p.version_id, 'match_id', p.match_id, 'actor', p.actor, 'data',
                        p.data, 'created_at', p.created_at, 'read_at', p.read_at)
                ORDER BY p.created_at DESC, p.id DESC)
            FROM page p), '[]'::json), 'unread', (SELECT count(*)
        FROM notifications u
        WHERE u.user_id = me.user_id
        AND u.read_at IS NULL), 'next_cursor', CASE
    WHEN (SELECT count(*)
        FROM page) = (SELECT n
        FROM lim) THEN (SELECT (to_json(x.created_at) #>> '{}') || '|' || x.id::text
        FROM page x
        ORDER BY x.created_at ASC, x.id ASC
        LIMIT 1)
    END ) AS body
FROM me
