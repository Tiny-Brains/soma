-- The note, refused on a listed word by this predicate, so a refused request changes nothing and
-- the `read` names the word. Blank clears it.
UPDATE model_versions v
   SET note = nullif(btrim(coalesce(($4)::text, '')), '')
  FROM live_sessions ls
 WHERE v.id = ($1)::uuid
   AND ls.sid = ($3)::uuid AND ls.user_id = ($2)::uuid
   AND model_writable_by(v.model_id, ls.user_id)
   AND text_hold_tag(($4)::text, false) IS NULL
