-- LIVE FIRST, THEN PAST, newest first within each, or the one `$1` names. Live is not disabled and
-- not past `ends_at`.
SELECT json_build_object('announcements', coalesce(json_agg(json_build_object(
           'id', a.id, 'kind', a.kind, 'body', a.body, 'link', a.link, 'dismissable', a.dismissable,
           'ends_at', a.ends_at, 'live', a.live, 'at', a.at, 'source', a.source,
           -- A clock's line (a round's countdown) has no publisher: null here.
           'published_by', pu.handle, 'published_at', a.published_at,
           'disabled_by', du.handle, 'disabled_at', a.disabled_at)
           ORDER BY a.live DESC, a.published_at DESC, a.id), '[]'::json)) AS body
  FROM (SELECT x.*, announcement_live(x) AS live
          FROM announcements x
         WHERE ($1)::uuid IS NULL OR x.id = ($1)::uuid
         ORDER BY live DESC, x.published_at DESC
         LIMIT 500) a
  LEFT JOIN users pu ON pu.id = a.published_by
  LEFT JOIN users du ON du.id = a.disabled_by
