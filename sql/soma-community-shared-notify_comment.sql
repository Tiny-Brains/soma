-- A COMMENT TELLS THE HOST'S OWNERS (thread_owners): a model's owner, or each owner seated in the
-- match -- never its author, and never the parent's author, whom notify_reply tells instead. Not
-- notable, so the default `replies` level skips it and `all` takes it. Keyed
-- comment:<thread>:<hour>: a busy thread is one line an hour, not one a comment. `$1`/`$2` as
-- notify_reply's.
WITH named AS (
    SELECT try_uuid(($1)::text) AS id
    UNION
    SELECT jsonb_uuids(($2)::jsonb)
), c AS (
    SELECT c.id, c.body, c.author_id, c.thread_id, t,
           (SELECT e.name FROM models e WHERE e.id = t.model_id) AS model,
           (SELECT p.author_id FROM comments p WHERE p.id = c.parent_id) AS parent_author
      FROM named
      JOIN comments c ON c.id = named.id AND c.state = 'live'
      JOIN threads t  ON t.id = c.thread_id
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, match_id, model_id,
                           actor, data, dedupe_key)
SELECT DISTINCT ON (o, c.thread_id)
       o, 'community', 'comment', 'info',
       '@' || left(au.handle, 64) || ' commented on ' || coalesce(left(c.model, 100), 'a match you played'),
       left(c.body, 200), comment_link(c.t, c.id), (c.t).match_id, (c.t).model_id, au.handle,
       jsonb_build_object('host',       thread_host(c.t),
                          'host_id',    thread_host_id(c.t),
                          'comment_id', c.id,
                          'excerpt',    left(c.body, 120)),
       'comment:' || c.thread_id || ':' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24')
  FROM c
 CROSS JOIN LATERAL thread_owners(c.t) o
  JOIN users au ON au.id = c.author_id
 WHERE o <> c.author_id
   AND o IS DISTINCT FROM c.parent_author
   AND notification_wanted(o, 'community', false)
 ORDER BY o, c.thread_id, c.id
ON CONFLICT (user_id, dedupe_key) DO NOTHING
