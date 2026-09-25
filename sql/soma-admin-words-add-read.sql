-- The word as the list holds it now, and whether its shape is one a list may hold at all.
WITH w AS (
    SELECT lower(btrim(coalesce(($1)::text, ''))) AS word
)
SELECT comment_word_ok(w.word) AS shape_ok,
       (SELECT json_build_object('id', cw.id, 'word', cw.word, 'added_by', u.handle, 'added_at', cw.added_at)
          FROM comment_words cw JOIN users u ON u.id = cw.added_by
         WHERE cw.word = w.word AND cw.removed_at IS NULL) AS body
  FROM w
