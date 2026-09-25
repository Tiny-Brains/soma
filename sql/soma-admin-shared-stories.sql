-- EVERY STORY WITH ITS STATE, newest edit first, or the one `$1` names: the list and the answer to
-- an action are one shape. The approved text is an excerpt; a held edit is whole, since it is what
-- an admin reads to decide.
SELECT json_build_object('stories', coalesce(json_agg(json_build_object(
           'model_id', s.model_id, 'model', e.name, 'owner', u.handle, 'baseline', u.role = 'baseline',
           'title', s.title, 'excerpt', left(s.body, 280),
           'held', s.hold_tag IS NOT NULL,
           'pending', story_pending_json(s),
           'featured', s.featured_at IS NOT NULL, 'featured_at', s.featured_at,
           'removed', s.removed_at IS NOT NULL, 'removed_at', s.removed_at,
           'approved_at', s.approved_at, 'updated_at', s.updated_at)
           ORDER BY s.updated_at DESC, s.model_id), '[]'::json)) AS body
  FROM (SELECT * FROM model_stories
         WHERE ($1)::uuid IS NULL OR model_id = ($1)::uuid
         ORDER BY updated_at DESC, model_id LIMIT 500) s
  JOIN models e ON e.id = s.model_id
  JOIN users u  ON u.id = e.owner_id
