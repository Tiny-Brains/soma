-- THE WHOLE ORDER OR NOTHING: `ids` must name every live pick exactly once, and position is its
-- place in the array. Ids are compared as text, so a malformed one is a mismatch, not a cast error.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), live AS (
    SELECT p.id::text AS id FROM picks p WHERE p.unpinned_at IS NULL
), wanted AS (
    SELECT o.id, o.ord
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(($3)::jsonb) = 'array'
                                          THEN ($3)::jsonb ELSE '[]'::jsonb END)
           WITH ORDINALITY AS o (id, ord)
), whole AS (
    SELECT (SELECT count(*) FROM wanted) = (SELECT count(*) FROM live)
       AND (SELECT count(DISTINCT id) FROM wanted) = (SELECT count(*) FROM wanted)
       AND NOT EXISTS (SELECT 1 FROM wanted w WHERE w.id NOT IN (SELECT id FROM live)) AS ok
), moved AS (
    UPDATE picks p
       SET position = w.ord
      FROM wanted w, whole, me
     WHERE whole.ok AND p.id::text = w.id AND p.unpinned_at IS NULL
    RETURNING p.id
)
INSERT INTO audit_log (admin_id, action, target_kind, detail)
SELECT me.id, 'pick.reorder', 'pick', jsonb_build_object('order', ($3)::jsonb)
  FROM me
 WHERE EXISTS (SELECT 1 FROM moved)
