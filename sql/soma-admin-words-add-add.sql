-- ADD ONE WORD, lower-cased and trimmed, with its audit line. comment_word_ok() is the CHECK's rule
-- as a predicate, so a malformed word is a row never written rather than a CHECK error, and a word
-- already listed conflicts on the live-word index and writes nothing. It applies to the next text.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), w AS (
    SELECT lower(btrim(coalesce(($3)::text, ''))) AS word
), added AS (
    INSERT INTO comment_words (word, added_by)
    SELECT w.word, me.id
      FROM me, w
     WHERE comment_word_ok(w.word)
    ON CONFLICT (word) WHERE removed_at IS NULL DO NOTHING
    RETURNING id, word
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'word.add', 'comment_word', a.id::text, jsonb_build_object('word', a.word)
  FROM added a, me
