-- A REPLY TELLS ITS PARENT'S AUTHOR: read off the rows, never the request -- only a comment that is
-- live now, and never to someone replying to themselves. `$1` is one comment, `$2` a JSON array of
-- them (an admin's approval of a selection). Keyed reply:<comment>, so it is said once whoever
-- writes it and however often.
WITH named AS (
    SELECT try_uuid(($1)::text) AS id
    UNION
    SELECT jsonb_uuids(($2)::jsonb)
), c AS (
    SELECT c.id, c.body, c.parent_id, c.author_id, t
      FROM named
      JOIN comments c ON c.id = named.id AND c.state = 'live' AND c.parent_id IS NOT NULL
      JOIN threads t  ON t.id = c.thread_id
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, match_id, model_id,
                           actor, data, dedupe_key)
SELECT p.author_id, 'community', 'reply', 'info',
       '@' || left(au.handle, 64) || ' replied to your comment',
       left(c.body, 200), comment_link(c.t, c.id), (c.t).match_id, (c.t).model_id, au.handle,
       jsonb_build_object('host',       thread_host(c.t),
                          'host_id',    thread_host_id(c.t),
                          'comment_id', c.id,
                          'parent_id',  c.parent_id,
                          'excerpt',    left(c.body, 120)),
       'reply:' || c.id
  FROM c
  JOIN comments p ON p.id = c.parent_id
  JOIN users au   ON au.id = c.author_id
 WHERE p.author_id <> c.author_id
   AND notification_wanted(p.author_id, 'community', true)
ON CONFLICT (user_id, dedupe_key) DO NOTHING
