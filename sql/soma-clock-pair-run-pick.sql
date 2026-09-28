-- ROUND-ROBIN OVER LIVE SEASONS (N30). Seasons overlap, so each tick pairs ONE live season of the
-- game -- one whose pending queue is emptiest, so a season that just took a burst yields to a
-- starved one on the next tick and none starves. Only a season that CAN pair is eligible: it has an
-- enabled board and at least one version to seat (active, or a verified candidate awaiting its
-- trial), so a boardless or empty season is never picked and never halts the run for the others. No
-- eligible season, no row, and the run halts -- the paused state one idle season already had.
--
-- A TIE ROTATES BY TICK, never by a fixed order. A settled ladder has no demand, so its queue stays
-- empty: under a fixed tie-break (the season number) the older season won every tick, found nothing
-- to pair, and the newer one was never picked at all. Now the seasons tied on the emptiest queue take
-- turns -- the tick index (this clock runs every 15 s) modulo how many are tied -- so each of n tied
-- seasons is picked every n-th tick whatever its demand.
WITH eligible AS (
    SELECT s.id, s.number,
           (SELECT count(*) FROM matches m WHERE m.season_id = s.id AND m.status = 'pending') AS pending
      FROM seasons s
     WHERE s.game_id = (SELECT id FROM games WHERE slug = ($1)::text) AND s.closed_at IS NULL
       AND EXISTS (SELECT 1 FROM season_maps sm WHERE sm.season_id = s.id AND sm.enabled)
       AND EXISTS (SELECT 1 FROM model_versions v WHERE v.season_id = s.id AND v.status IN ('active', 'verified'))
), tied AS (
    SELECT id, row_number() OVER (ORDER BY number) - 1 AS i, count(*) OVER () AS n
      FROM eligible
     WHERE pending = (SELECT min(pending) FROM eligible)
)
SELECT id AS season_id
  FROM tied
 WHERE i = (floor(extract(epoch FROM now()) / 15)::bigint % n)
