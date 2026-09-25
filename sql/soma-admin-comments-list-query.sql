-- THE COMMENTS DESK: one of three lists, each its own branch so each reads its own index.
--   held      oldest first (comments_held_idx), an OFFSET cursor
--   reported  most reported first, then most recently reported, live or held ones only; an OFFSET
--             cursor, since a report count moves under a keyset
--   all       newest first (comments_recent_idx), a keyset cursor `<created_at>|<id>`
-- `q` narrows any of them through `filtered`: `@handle` to one author, read off comments_author_idx,
-- anything else to a substring of the text. Every row is the whole comment, whatever its state.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), q AS (
    SELECT coalesce(($3)::text, 'held') AS view,
           CASE WHEN left(s.s, 1) = '@' THEN substr(s.s, 2) END AS handle,
           CASE WHEN left(s.s, 1) <> '@' THEN s.s END AS text,
           CASE WHEN coalesce(($5)::text, '') ~ '^[0-9]{1,6}$' THEN ($5)::text::int ELSE 0 END AS o
      FROM (SELECT nullif(btrim(coalesce(($4)::text, '')), '') AS s) s
), filtered AS NOT MATERIALIZED (
    SELECT c.* FROM comments c, q
     WHERE q.handle IS NULL AND (q.text IS NULL OR strpos(lower(c.body), lower(q.text)) > 0)
    UNION ALL
    SELECT c.* FROM comments c, q, users u
     WHERE q.handle IS NOT NULL AND lower(u.handle) = lower(q.handle) AND c.author_id = u.id
), held AS (
    SELECT f.*, row_number() OVER (ORDER BY f.created_at, f.id) AS ord
      FROM filtered f, q
     WHERE q.view = 'held' AND f.state = 'held'
     ORDER BY f.created_at, f.id
    OFFSET (SELECT o FROM q) LIMIT 50
), reported AS (
    SELECT f.*, row_number() OVER (ORDER BY r.n DESC, r.last DESC, f.id) AS ord
      FROM (SELECT r.comment_id, count(*) AS n, max(r.created_at) AS last
              FROM comment_reports r, q WHERE q.view = 'reported' GROUP BY r.comment_id) r
      JOIN filtered f ON f.id = r.comment_id AND f.state IN ('live', 'held')
     ORDER BY r.n DESC, r.last DESC, f.id
    OFFSET (SELECT o FROM q) LIMIT 50
), everything AS (
    SELECT f.*, row_number() OVER (ORDER BY f.created_at DESC, f.id DESC) AS ord
      FROM filtered f, q
     WHERE q.view = 'all'
       AND (($5)::text IS NULL
            OR (f.created_at, f.id) < (split_part(($5)::text, '|', 1)::timestamptz,
                                       try_uuid(split_part(($5)::text, '|', 2))))
     ORDER BY f.created_at DESC, f.id DESC
     LIMIT 50
), page AS (
    SELECT * FROM held UNION ALL SELECT * FROM reported UNION ALL SELECT * FROM everything
)
SELECT json_build_object(
    'view', (SELECT view FROM q),
    'counts', json_build_object(
        'held',     (SELECT count(*) FROM comments c WHERE c.state = 'held'),
        'reported', (SELECT count(*) FROM (SELECT DISTINCT r.comment_id FROM comment_reports r) r
                      WHERE EXISTS (SELECT 1 FROM comments c
                                     WHERE c.id = r.comment_id AND c.state IN ('live', 'held')))),
    'comments', coalesce((SELECT json_agg(json_build_object(
                    'id',         p.id,
                    'state',      p.state,
                    'hold_tag',   p.hold_tag,
                    'body',       p.body,
                    'parent_id',  p.parent_id,
                    'root_id',    p.root_id,
                    'created_at', p.created_at,
                    'decided_at', p.decided_at,
                    'decided_by', (SELECT d.handle FROM users d WHERE d.id = p.decided_by),
                    'author',     json_build_object('id', a.id, 'handle', a.handle,
                                                    'commenting_off_until', commenting_off_until(a)),
                    'host',       thread_host(t),
                    'host_id',    thread_host_id(t),
                    'host_name',  (SELECT e.name FROM models e WHERE e.id = t.model_id),
                    'thread',     json_build_object('id', t.id, 'locked', t.locked_at IS NOT NULL),
                    'reports',    (SELECT json_build_object(
                                       'count', coalesce(sum(g.n), 0),
                                       'reasons', coalesce(json_object_agg(coalesce(g.reason, 'none'), g.n)
                                                             FILTER (WHERE g.n IS NOT NULL), '{}'::json),
                                       'recent', (SELECT coalesce(json_agg(json_build_object(
                                                             'reporter', ru.handle, 'reason', r.reason,
                                                             'words', r.words, 'at', r.created_at)
                                                             ORDER BY r.created_at DESC), '[]'::json)
                                                    FROM (SELECT * FROM comment_reports r
                                                           WHERE r.comment_id = p.id
                                                           ORDER BY r.created_at DESC LIMIT 10) r
                                                    JOIN users ru ON ru.id = r.reporter_id))
                                     FROM (SELECT r.reason, count(*) AS n FROM comment_reports r
                                            WHERE r.comment_id = p.id GROUP BY r.reason) g))
                    ORDER BY p.ord)
                  FROM page p
                  JOIN users a   ON a.id = p.author_id
                  JOIN threads t ON t.id = p.thread_id), '[]'::json),
    'next_cursor', CASE WHEN (SELECT count(*) FROM page) < 50 THEN NULL
                        WHEN (SELECT view FROM q) = 'all'
                        THEN (SELECT (to_json(x.created_at) #>> '{}') || '|' || x.id::text
                                FROM page x ORDER BY x.created_at, x.id LIMIT 1)
                        ELSE ((SELECT o FROM q) + 50)::text END) AS body
  FROM me
