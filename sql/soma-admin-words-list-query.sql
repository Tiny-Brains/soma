-- The listed words, alphabetically: what text_hold_tag() holds a comment or a story on and refuses
-- a bio or a note for. A removed word is off the list and on the audit log.
SELECT json_build_object('words', coalesce((
    SELECT json_agg(json_build_object('id', w.id, 'word', w.word, 'added_by', u.handle,
                                      'added_at', w.added_at) ORDER BY w.word)
      FROM comment_words w JOIN users u ON u.id = w.added_by
     WHERE w.removed_at IS NULL), '[]'::json)) AS body
  FROM live_sessions ls
  JOIN users me ON me.id = ls.user_id AND me.role = 'admin'
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
