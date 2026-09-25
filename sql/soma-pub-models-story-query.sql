-- The approved text only. A first story still held, or one an admin removed, is no story here.
SELECT json_build_object('model_id', s.model_id, 'title', s.title, 'body', s.body,
                         'featured', s.featured_at IS NOT NULL, 'featured_at', s.featured_at,
                         'updated_at', s.approved_at) AS body
  FROM model_stories s
 WHERE s.model_id = ($1)::uuid
   AND story_public(s)
