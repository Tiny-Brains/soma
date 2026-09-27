-- ROUND-ROBIN OVER LIVE SEASONS (N30). Seasons overlap, so each tick pairs ONE live season of the
-- game -- the one whose pending queue is emptiest, so a season that just took a burst yields to a
-- starved one on the next tick and none starves. Only a season that CAN pair is eligible: it has an
-- enabled board and at least one version to seat (active, or a verified candidate awaiting its
-- trial), so a boardless or empty season is never picked and never halts the run for the others. No
-- eligible season, no row, and the run halts -- the paused state one idle season already had.
SELECT s.id AS season_id
  FROM seasons s
 WHERE s.game_id = (SELECT id FROM games WHERE slug = ($1)::text) AND s.closed_at IS NULL
   AND EXISTS (SELECT 1 FROM season_maps sm WHERE sm.season_id = s.id AND sm.enabled)
   AND EXISTS (SELECT 1 FROM model_versions v WHERE v.season_id = s.id AND v.status IN ('active', 'verified'))
 ORDER BY (SELECT count(*) FROM matches m WHERE m.season_id = s.id AND m.status = 'pending') ASC,
          s.number
 LIMIT 1
