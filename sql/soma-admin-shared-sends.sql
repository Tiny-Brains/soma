-- THE SENT LOG, newest first, or the one `$1` names: each send with who sent it, its recipient
-- count, and how many of those rows are read -- counted per send shown, off the partial index on
-- read broadcasts, never over every broadcast ever sent. A broadcast's key is `notify:<send>`.
SELECT json_build_object('sends', coalesce(json_agg(json_build_object(
           'id', s.id, 'subject', s.subject, 'link', s.link, 'audience', s.audience,
           'sent_by', u.handle, 'sent_at', s.sent_at, 'recipients', s.recipients,
           'read', (SELECT count(*) FROM notifications n
                     WHERE n.kind = 'broadcast' AND n.read_at IS NOT NULL
                       AND n.dedupe_key = 'notify:' || s.id::text))
           ORDER BY s.sent_at DESC, s.id), '[]'::json)) AS body
  FROM (SELECT * FROM notify_sends
         WHERE ($1)::uuid IS NULL OR id = ($1)::uuid
         ORDER BY sent_at DESC, id LIMIT 200) s
  JOIN users u ON u.id = s.sent_by
