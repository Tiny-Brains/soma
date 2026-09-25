-- Save, publish or unpublish: every field is kept unless sent. Publishing stamps published_at
-- once and keeps it through later saves; unpublishing clears it, so a republish is a new date.
-- The slug stays unique by the NOT EXISTS, which turns a taken slug into no row rather than a
-- unique violation.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), edited AS (
    UPDATE posts p
       SET slug  = coalesce(($4)::text, p.slug),
           title = coalesce(btrim(($5)::text), p.title),
           body  = coalesce(($6)::text, p.body),
           published_at = CASE WHEN ($7)::boolean IS TRUE  THEN coalesce(p.published_at, now())
                               WHEN ($7)::boolean IS FALSE THEN NULL
                               ELSE p.published_at END,
           updated_at = now()
      FROM me
     WHERE p.id = ($3)::uuid
       AND (($4)::text IS NULL
            OR (slug_ok(($4)::text, 80)
                AND NOT EXISTS (SELECT 1 FROM posts o WHERE o.slug = ($4)::text AND o.id <> p.id)))
       AND (($5)::text IS NULL OR line_ok(btrim(($5)::text), 120))
       AND (($6)::text IS NULL OR char_length(($6)::text) <= 100000)
    -- The subquery reads the statement's snapshot, so `was_published` is the row before this save.
    RETURNING p.id, p.slug, p.published_at,
              (SELECT o.published_at IS NOT NULL FROM posts o WHERE o.id = p.id) AS was_published
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id,
       CASE WHEN edited.published_at IS NOT NULL AND NOT edited.was_published THEN 'post.publish'
            WHEN edited.published_at IS NULL AND edited.was_published     THEN 'post.unpublish'
            ELSE 'post.update' END,
       'post', edited.id::text,
       jsonb_build_object('slug', edited.slug, 'published', edited.published_at IS NOT NULL)
  FROM edited, me
