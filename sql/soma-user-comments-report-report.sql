-- ONE REPORT PER READER PER COMMENT: a second one replaces the first's reason and words. Only a live
-- comment, and never your own -- you delete that instead.
INSERT INTO comment_reports (comment_id, reporter_id, reason, words)
SELECT c.id, ls.user_id, ($4)::text, nullif(btrim(coalesce(($5)::text, '')), '')
  FROM live_sessions ls
  JOIN comments c ON c.id = try_uuid(($3)::text) AND c.state = 'live' AND c.author_id <> ls.user_id
 WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
ON CONFLICT (comment_id, reporter_id) DO UPDATE SET reason = EXCLUDED.reason, words = EXCLUDED.words
