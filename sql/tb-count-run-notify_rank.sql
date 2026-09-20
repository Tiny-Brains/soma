WITH m AS (
    SELECT mt.id, mt.season_id, se.slug AS season, se.rules, g.slug AS game
      FROM matches mt
      JOIN seasons se ON se.id = mt.season_id
      JOIN games g    ON g.id = mt.game_id
     WHERE mt.id = ($1)::uuid AND mt.status = 'rated' AND mt.trial_version_id IS NULL
), ev AS (
    SELECT e.version_id, e.ladder, e.sigma_after,
           e.mu_before - 3 * e.sigma_before AS before,
           e.mu_after  - 3 * e.sigma_after  AS after
      FROM rating_events e JOIN m ON e.match_id = m.id
), field AS MATERIALIZED (
    SELECT l.ladder, f.version_id, coalesce(ev.before, f.conservative) AS before, f.conservative AS after
      FROM m
     CROSS JOIN (SELECT DISTINCT ladder FROM ev) l
     CROSS JOIN LATERAL ladder_field(m.season_id, l.ladder) f
      LEFT JOIN ev ON ev.version_id = f.version_id AND ev.ladder = l.ladder
), moved AS (
    SELECT ev.version_id, ev.ladder, ev.sigma_after, ev.after,
           (SELECT count(*) + 1 FROM field x
             WHERE x.ladder = ev.ladder AND x.version_id <> ev.version_id
               AND (x.before > ev.before OR (x.before = ev.before AND x.version_id < ev.version_id))) AS prev_rank,
           (SELECT count(*) + 1 FROM field x
             WHERE x.ladder = ev.ladder AND x.version_id <> ev.version_id
               AND (x.after > ev.after OR (x.after = ev.after AND x.version_id < ev.version_id))) AS rank,
           (SELECT count(*) FROM field x WHERE x.ladder = ev.ladder) AS field
      FROM ev
     WHERE EXISTS (SELECT 1 FROM field x WHERE x.ladder = ev.ladder AND x.version_id = ev.version_id)
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, match_id, data, dedupe_key)
SELECT e.owner_id, 'ratings', 'rank',
       CASE WHEN mv.rank < mv.prev_rank THEN 'ok' ELSE 'info' END,
       e.name || ' v' || v.version ||
         CASE WHEN mv.rank < mv.prev_rank THEN ' rose to ' ELSE ' fell to ' END ||
         (mv.rank)::text || CASE WHEN (mv.rank) % 100 IN (11, 12, 13) THEN 'th' WHEN (mv.rank) % 10 = 1 THEN 'st' WHEN (mv.rank) % 10 = 2 THEN 'nd' WHEN (mv.rank) % 10 = 3 THEN 'rd' ELSE 'th' END || ' on the ' || mv.ladder || ' ladder',
       CASE WHEN mv.rank < mv.prev_rank THEN 'Up from ' ELSE 'Down from ' END ||
         (mv.prev_rank)::text || CASE WHEN (mv.prev_rank) % 100 IN (11, 12, 13) THEN 'th' WHEN (mv.prev_rank) % 10 = 1 THEN 'st' WHEN (mv.prev_rank) % 10 = 2 THEN 'nd' WHEN (mv.prev_rank) % 10 = 3 THEN 'rd' ELSE 'th' END || ' of ' || mv.field || '.',
       '/leaderboard?season=' || m.season ||
         CASE WHEN mv.ladder = 'open' THEN '' ELSE '&ladder=' || mv.ladder END,
       m.game, m.season, e.id, v.id, m.id,
       jsonb_build_object('ladder', mv.ladder, 'rank', mv.rank, 'prev_rank', mv.prev_rank,
                          'of', mv.field, 'class', v.weight_class,
                          'rating', round(mv.after::numeric, 2)),
       'rank:' || m.id || ':' || v.id || ':' || mv.ladder
  FROM m
 CROSS JOIN moved mv
  JOIN model_versions v ON v.id = mv.version_id
  JOIN models e         ON e.id = v.model_id
 WHERE mv.rank <> mv.prev_rank
   AND mv.sigma_after <= coalesce((m.rules -> 'rating' ->> 'settled_sigma')::float8, ($2)::float8)
   AND notification_wanted(e.owner_id, 'ratings')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
