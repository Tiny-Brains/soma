-- "You're in <season>" (S8): to every account a participant row just added was pinned to, read off
-- the rows this run's last minute wrote, keyed on the row. An invite still waiting for its account
-- tells nobody yet; the season is on the member's list once they sign in.
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, game, season, dedupe_key)
SELECT sp.user_id, 'season', 'season', 'info', 'You''re in ' || s.name,
       CASE WHEN s.visibility = 'private' THEN 'A private season: only its members see it.'
            ELSE 'You may enter it.' END,
       '/?season=' || s.slug, g.slug, s.slug, 'participant:' || sp.id
  FROM season_participants sp
  JOIN seasons s ON s.id = sp.season_id
  JOIN games g   ON g.id = s.game_id
 WHERE sp.season_id = ($1)::uuid AND sp.user_id IS NOT NULL AND sp.removed_at IS NULL
   AND sp.added_at > now() - interval '1 minute'
   AND notification_wanted(sp.user_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
