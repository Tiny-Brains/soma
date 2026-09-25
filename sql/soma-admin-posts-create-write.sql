-- A draft, and its audit line. The predicates ask the table CHECKs' own functions, so a bad field
-- is a row never written rather than a 500; a taken slug is the conflict.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), made AS (
    INSERT INTO posts (id, slug, title, author_id, body)
    SELECT ($3)::uuid, ($4)::text, btrim(($5)::text), me.id, coalesce(($6)::text, '')
      FROM me
     WHERE slug_ok(($4)::text, 80) AND line_ok(btrim(($5)::text), 120)
       AND char_length(coalesce(($6)::text, '')) <= 100000
    ON CONFLICT DO NOTHING
    RETURNING id, slug, title
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'post.create', 'post', made.id::text, jsonb_build_object('slug', made.slug, 'title', made.title)
  FROM made, me
