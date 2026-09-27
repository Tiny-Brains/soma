WITH me AS (
    SELECT u.id
    FROM live_sessions ls
    JOIN users u ON u.id = ls.user_id
    AND u.role = 'admin'
    WHERE ls.sid = ($2)::uuid
    AND ls.user_id = ($1)::uuid ),
deployment AS (
    SELECT string_to_array(coalesce(($3)::text, ''), ',') AS ids ),
q AS (
    SELECT nullif(lower(btrim(coalesce(($4)::text, ''))), '') AS s ),
seen AS (
    SELECT s.user_id, max(s.last_seen_at) AS at
    FROM sessions s
    GROUP BY s.user_id ),
rows AS (
    SELECT u.id, u.role, u.handle, u.display_name, seen.at AS seen_at, json_build_object('id', u.id, 'handle',
            u.handle, 'display_name', u.display_name, 'role', u.role, 'by_deployment', EXISTS (SELECT 1
                FROM identities i WHERE i.user_id = u.id AND (i.provider || ':' || i.subject) = ANY (d.ids)),
            'you', u.id = me.id, 'joined_at', u.created_at, 'last_seen_at',
            seen.at, 'commenting', CASE
        WHEN commenting_off_until(u) IS NULL THEN 'on'
        ELSE 'off'
        END, 'comments_off_until', commenting_off_until(u)) AS j
    FROM users u
    CROSS JOIN me
    CROSS JOIN deployment d
    LEFT JOIN seen ON seen.user_id = u.id
    WHERE u.role <> 'baseline' ),
matching AS (
    SELECT r.*
    FROM rows r, q
    WHERE r.role <> 'admin'
    AND (q.s IS NULL
        OR strpos(lower(r.handle), q.s) > 0
        OR strpos(lower(coalesce(r.display_name, '')), q.s) > 0) ),
shown AS (
    SELECT *
    FROM matching
    ORDER BY seen_at DESC NULLS LAST, lower(handle)
    LIMIT 50 ),
listed AS (
    -- Every row the page draws -- the admins and the page of competitors -- with its comment counts,
    -- each read off comments_author_idx for that user alone and merged once.
    SELECT x.role, x.handle, x.seen_at, x.j::jsonb || jsonb_build_object('comments', k.c) AS j
    FROM (SELECT s.role, s.handle, s.seen_at, s.j, s.id
            FROM shown s
          UNION ALL
          SELECT r.role, r.handle, r.seen_at, r.j, r.id
            FROM rows r
           WHERE r.role = 'admin') x
    CROSS JOIN LATERAL (SELECT jsonb_build_object('held', count(*) FILTER (WHERE c.state = 'held'),
                                   'reported', count(*) FILTER (WHERE EXISTS (SELECT 1
                                                   FROM comment_reports r
                                                   WHERE r.comment_id = c.id)),
                                   'removed', count(*) FILTER (WHERE c.state = 'removed')) AS c
            FROM comments c
            WHERE c.author_id = x.id) k )
SELECT json_build_object('admins', coalesce((SELECT json_agg(l.j
                ORDER BY lower(l.handle))
            FROM listed l
            WHERE l.role = 'admin'), '[]'::json), 'users', coalesce((SELECT json_agg(l.j
                ORDER BY l.seen_at DESC NULLS LAST, lower(l.handle))
            FROM listed l
            WHERE l.role <> 'admin'), '[]'::json), 'matching', (SELECT count(*)
        FROM matching)) AS body
FROM me
