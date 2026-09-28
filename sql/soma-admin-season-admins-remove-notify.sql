-- "You no longer run <season>" (S8), read off the membership the remove just ended, keyed on it.
INSERT INTO notifications (user_id, category, kind, tone, subject, link, game, season, dedupe_key)
SELECT sa.user_id, 'season', 'season', 'info', 'You no longer run ' || s.name,
       '/?season=' || s.slug, g.slug, s.slug, 'season-admin-removed:' || sa.id
  FROM season_admins sa
  JOIN seasons s ON s.id = sa.season_id
  JOIN games g   ON g.id = s.game_id
  JOIN users u   ON u.id = sa.user_id
 WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND lower(u.handle) = lower(($3)::text)
   AND sa.removed_at > now() - interval '1 minute'
   AND notification_wanted(sa.user_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
