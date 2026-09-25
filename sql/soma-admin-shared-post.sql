-- One post, draft or published, whole: the Write page's shape.
SELECT json_build_object('id', p.id, 'slug', p.slug, 'title', p.title, 'body', p.body,
                         'author', u.handle, 'published', p.published_at IS NOT NULL,
                         'published_at', p.published_at, 'created_at', p.created_at,
                         'updated_at', p.updated_at) AS body
  FROM posts p
  JOIN users u ON u.id = p.author_id
 WHERE p.id = ($1)::uuid
