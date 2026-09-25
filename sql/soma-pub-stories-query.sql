-- Posts and featured stories in one keyset over (at, id): a post's published_at, a story's
-- featured_at. Each branch walks its own partial index newest first, so a page reads a page.
WITH lim AS (
    SELECT least(greatest(coalesce(($3)::int, 20), 1), 60) AS n
), k AS (
    SELECT coalesce(($1)::text, 'all') AS kind
), items AS NOT MATERIALIZED (
    SELECT p.published_at AS at, p.id,
           json_build_object('kind', 'team', 'id', p.id, 'slug', p.slug, 'title', p.title,
                             'excerpt', left(p.body, 280), 'author', u.handle, 'baseline', false,
                             'at', p.published_at) AS item
      FROM posts p
      JOIN users u ON u.id = p.author_id
     WHERE p.published_at IS NOT NULL AND (SELECT kind FROM k) IN ('all', 'team')
    UNION ALL
    SELECT s.featured_at, s.model_id,
           json_build_object('kind', 'model', 'model_id', s.model_id, 'model', e.name,
                             'title', s.title, 'excerpt', left(s.body, 280), 'author', u.handle,
                             'baseline', u.role = 'baseline',
                             'class', (SELECT v.weight_class FROM model_versions v
                                        WHERE v.model_id = e.id ORDER BY v.created_at DESC LIMIT 1),
                             'at', s.featured_at)
      FROM model_stories s
      JOIN models e ON e.id = s.model_id
      JOIN users u  ON u.id = e.owner_id
     WHERE s.featured_at IS NOT NULL AND story_public(s)
       AND (SELECT kind FROM k) IN ('all', 'model')
), page AS (
    SELECT at, id, item
      FROM items
     WHERE ($2)::text IS NULL
        OR (at, id) < (split_part(($2)::text, '|', 1)::timestamptz, split_part(($2)::text, '|', 2)::uuid)
     ORDER BY at DESC, id DESC
     LIMIT (SELECT n FROM lim)
)
SELECT json_build_object(
    'kind',  (SELECT kind FROM k),
    'total', CASE WHEN ($2)::text IS NULL THEN (SELECT count(*) FROM items) END,
    'stories', coalesce((SELECT json_agg(p.item ORDER BY p.at DESC, p.id DESC) FROM page p), '[]'::json),
    'next_cursor', CASE WHEN (SELECT count(*) FROM page) = (SELECT n FROM lim)
                        THEN (SELECT (to_json(x.at) #>> '{}') || '|' || x.id::text
                                FROM page x ORDER BY x.at ASC, x.id ASC LIMIT 1) END) AS body
