-- ONE UPSERT decides the story. text_hold_tag() over the title and the body, links allowed: clean,
-- and the text replaces the approved one at once and clears any held edit; tripped, and it waits
-- in pending_* with its tag while the public keeps the approved text. The writer is the model's
-- owner, or an admin for a baseline's model, whose story the team writes. A removed story stays
-- removed through an edit: only an admin restores it.
WITH me AS (
    SELECT e.id
      FROM models e
      JOIN live_sessions ls ON ls.sid = ($3)::uuid AND ls.user_id = ($2)::uuid
     WHERE e.id = ($1)::uuid
       AND model_writable_by(e.id, ls.user_id)
), t AS (
    SELECT btrim(($4)::text) AS title, ($5)::text AS body,
           text_hold_tag(($4)::text || E'\n' || ($5)::text, false) AS tag
)
INSERT INTO model_stories AS s (model_id, title, body, pending_title, pending_body, hold_tag,
                                updated_at, approved_at)
SELECT me.id,
       CASE WHEN t.tag IS NULL THEN t.title END,     CASE WHEN t.tag IS NULL THEN t.body END,
       CASE WHEN t.tag IS NOT NULL THEN t.title END, CASE WHEN t.tag IS NOT NULL THEN t.body END,
       t.tag, now(), CASE WHEN t.tag IS NULL THEN now() END
  FROM me, t
 WHERE line_ok(t.title, 80)
   AND btrim(t.body) <> '' AND char_length(t.body) <= 20000
ON CONFLICT (model_id) DO UPDATE
   SET title         = coalesce(excluded.title, s.title),
       body          = coalesce(excluded.body, s.body),
       pending_title = excluded.pending_title,
       pending_body  = excluded.pending_body,
       hold_tag      = excluded.hold_tag,
       updated_at    = now(),
       approved_at   = coalesce(excluded.approved_at, s.approved_at)
