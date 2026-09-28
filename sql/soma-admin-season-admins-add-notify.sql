-- "You now run <season>": to the account a platform admin just made a season admin of it (S8),
-- read off the row the insert wrote in this run's last minute, keyed on the membership so a rerun
-- writes nothing. Category `season`, linking the season's desk.
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link, game, season, dedupe_key)
SELECT sa.user_id, 'season', 'season', 'info', 'You now run ' || s.name,
       'You manage its participants, boards, baselines and runners.',
       '/season-admin?season=' || s.slug, g.slug, s.slug, 'season-admin:' || sa.id
  FROM season_admins sa
  JOIN seasons s ON s.id = sa.season_id
  JOIN games g   ON g.id = s.game_id
  JOIN users u   ON u.id = sa.user_id
 WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND lower(u.handle) = lower(($3)::text)
   AND sa.removed_at IS NULL AND sa.added_at > now() - interval '1 minute'
   AND notification_wanted(sa.user_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
