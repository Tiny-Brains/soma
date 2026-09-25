-- A key the body leaves out keeps its value; a key sent empty or blank clears it to null. The bio
-- is refused on a listed word here, and the `read` says which word, so a refused request changes
-- nothing -- not even the display name beside it.
UPDATE users u
   SET display_name = CASE WHEN ($3)::jsonb ? 'display_name'
                           THEN nullif(btrim(coalesce(($3)::jsonb ->> 'display_name', '')), '')
                           ELSE u.display_name END,
       bio          = CASE WHEN ($3)::jsonb ? 'bio'
                           THEN nullif(btrim(coalesce(($3)::jsonb ->> 'bio', '')), '')
                           ELSE u.bio END
  FROM live_sessions ls
 WHERE u.id = ($1)::uuid AND ls.sid = ($2)::uuid AND ls.user_id = u.id
   AND text_hold_tag(($3)::jsonb ->> 'bio', false) IS NULL
