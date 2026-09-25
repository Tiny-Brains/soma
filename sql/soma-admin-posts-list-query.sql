-- Drafts and published, newest edit first, without the text: the list is a table of rows.
SELECT json_build_object('posts', coalesce(json_agg(json_build_object(
           'id', p.id, 'slug', p.slug, 'title', p.title, 'author', u.handle,
           'published', p.published_at IS NOT NULL, 'published_at', p.published_at,
           'created_at', p.created_at, 'updated_at', p.updated_at)
           ORDER BY p.updated_at DESC, p.id DESC), '[]'::json)) AS body
  FROM (SELECT * FROM posts ORDER BY updated_at DESC, id DESC LIMIT 500) p
  JOIN users u ON u.id = p.author_id
