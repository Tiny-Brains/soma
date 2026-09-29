-- SHARED by the public route (no session: $4 and $5 are null, the anonymous public) and the
-- member's /v1/private/threads (the session's claims): session_viewer() is the viewer, so a private
-- season's match is a host to whoever may see its season (BRD Q8) and to nobody else.
-- ONE HOST'S THREAD, a page of twenty top-level comments newest first, each with every reply under
-- it oldest first (the replies share its root_id, so one read of comments_thread_idx fetches
-- them). The public sees `live` comments, and a removed or deleted one as a placeholder while a
-- live comment still hangs beneath it -- comment_json() blanks its author and text. `found` is
-- false for a match the viewer may not see, which answers 404 like one that does not exist.
WITH RECURSIVE host AS (
    SELECT t.id, t.comments, t.locked_at
      FROM threads t
     WHERE t.match_id = try_uuid(($1)::text) OR t.model_id = try_uuid(($2)::text)
), found AS (
    SELECT thread_host_ok(try_uuid(($1)::text), try_uuid(($2)::text),
                          session_viewer(($4)::uuid, ($5)::uuid)) AS ok
), roots AS (
    SELECT c AS cr, c.id, c.thread_id, c.created_at
      FROM host
      JOIN comments c ON c.thread_id = host.id AND c.parent_id IS NULL
     WHERE (c.state = 'live'
            OR (c.state IN ('removed', 'deleted')
                AND EXISTS (SELECT 1 FROM comments r
                             WHERE r.thread_id = c.thread_id AND r.root_id = c.id
                               AND r.id <> c.id AND r.state = 'live')))
       AND (($3)::text IS NULL
            OR (c.created_at, c.id) < (try_timestamptz(split_part(($3)::text, '|', 1)),
                                       try_uuid(split_part(($3)::text, '|', 2))))
     ORDER BY c.created_at DESC, c.id DESC
     LIMIT 20
), replies AS (
    SELECT c AS cx, c.id, c.parent_id, c.root_id, c.state, c.created_at
      FROM roots r
      JOIN comments c ON c.thread_id = r.thread_id AND c.root_id = r.id AND c.id <> r.id
), kept AS (
    -- A live reply, and every ancestor of one: a deleted reply stays a placeholder only while
    -- something live still hangs beneath it.
    SELECT x.id, x.parent_id FROM replies x WHERE x.state = 'live'
    UNION
    SELECT p.id, p.parent_id FROM replies p JOIN kept k ON p.id = k.parent_id
)
SELECT found.ok AS found, json_build_object(
    'thread_id', host.id,
    'comments',  coalesce(host.comments, 0),
    'locked',    host.locked_at IS NOT NULL,
    'roots', coalesce((SELECT json_agg(comment_json(r.cr)::jsonb || jsonb_build_object(
                  'replies', coalesce((SELECT jsonb_agg(comment_json(x.cx)::jsonb ORDER BY x.created_at, x.id)
                                         FROM replies x
                                        WHERE x.root_id = r.id AND x.id IN (SELECT k.id FROM kept k)),
                                      '[]'::jsonb))
                  ORDER BY r.created_at DESC, r.id DESC)
                 FROM roots r), '[]'::json),
    'next_cursor', CASE WHEN (SELECT count(*) FROM roots) = 20
                        THEN (SELECT (to_json(r.created_at) #>> '{}') || '|' || r.id::text
                                FROM roots r ORDER BY r.created_at, r.id LIMIT 1) END) AS body
  FROM found
  LEFT JOIN host ON true
