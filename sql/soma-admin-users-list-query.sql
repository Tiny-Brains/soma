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
    SELECT u.role, u.handle, u.display_name, seen.at AS seen_at, json_build_object('id', u.id, 'handle',
            u.handle, 'display_name', u.display_name, 'role', u.role, 'by_deployment', coalesce(u.github_id::text
                = ANY (d.ids), false), 'you', u.id = me.id, 'joined_at', u.created_at, 'last_seen_at',
            seen.at) AS j
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
    LIMIT 50 )
SELECT json_build_object('admins', coalesce((SELECT json_agg(r.j
                ORDER BY lower(r.handle))
            FROM rows r
            WHERE r.role = 'admin'), '[]'::json), 'users', coalesce((SELECT json_agg(s.j
                ORDER BY s.seen_at DESC NULLS LAST, lower(s.handle))
            FROM shown s), '[]'::json), 'matching', (SELECT count(*)
        FROM matching)) AS body
FROM me
