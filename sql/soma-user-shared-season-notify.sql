-- A SEASON'S SENDS AND ITS AUDIENCE, for its season admins: how many people a send would reach now
-- (season_audience, those who want season notifications), and every send made to the season,
-- newest first, with how many read it. The platform's own sends to the season (audience naming it)
-- are listed too.
SELECT json_build_object(
         'recipients', (SELECT count(*) FROM season_audience(($1)::uuid) a
                         WHERE notification_wanted(a.user_id, 'season')),
         'sends', coalesce((SELECT json_agg(json_build_object(
                     'id', n.id, 'subject', n.subject, 'link', n.link, 'sent_by', u.handle,
                     'sent_at', n.sent_at, 'recipients', n.recipients,
                     'read', (SELECT count(*) FROM notifications x
                               WHERE x.dedupe_key = 'notify:' || n.id AND x.read_at IS NOT NULL))
                     ORDER BY n.sent_at DESC)
                    FROM notify_sends n JOIN users u ON u.id = n.sent_by
                   WHERE n.audience ->> 'game' = ($2)::text AND n.audience ->> 'season' = ($3)::text),
                  '[]'::json)) AS body
