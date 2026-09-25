SELECT json_build_object('id', p.id, 'slug', p.slug, 'title', p.title, 'body', p.body,
                         'author', u.handle, 'published_at', p.published_at,
                         'updated_at', p.updated_at) AS body
  FROM posts p
  JOIN users u ON u.id = p.author_id
 WHERE p.slug = ($1)::text AND p.published_at IS NOT NULL
