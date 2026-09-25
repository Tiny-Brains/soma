-- The live announcements, newest first: not disabled and not past their end.
SELECT json_build_object(
        'announcements', coalesce((SELECT json_agg(json_build_object(
                                       'id', a.id, 'kind', a.kind, 'body', a.body, 'link', a.link,
                                       'dismissable', a.dismissable, 'ends_at', a.ends_at,
                                       'published_at', a.published_at)
                                       ORDER BY a.published_at DESC)
                                     FROM announcements a
                                    WHERE announcement_live(a)), '[]'::json)) AS body
