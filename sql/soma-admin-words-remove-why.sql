SELECT true AS body FROM comment_words w WHERE w.id = try_uuid(($1)::text)
