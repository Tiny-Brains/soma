-- ROUND-ROBIN OVER LIVE SEASONS (N30). Seasons overlap, so each tick pairs ONE live season of the
-- game -- each in turn, so a season that just took a burst yields to the next one and none starves.
-- Only a season that CAN pair is eligible: it has an
-- enabled board and at least one version to seat (active, or a verified candidate awaiting its
-- trial), so a boardless or empty season is never picked and never halts the run for the others. No
-- eligible season, no row, and the run halts -- the paused state one idle season already had.
--
-- THE ROTATION IS OVER EVERY ELIGIBLE SEASON, never over the emptiest ones only. A settled ladder
-- has no demand, so its queue stays empty -- and "emptiest queue" makes empty the WINNING value:
-- rotating only among the seasons tied on `min(pending)` left a quiet season strictly the minimum on
-- every tick, so it won every tick for ever, while the busy season -- the one with pending > 0, the
-- only evidence that anyone is playing -- was never picked until its queue drained to exactly zero.
-- The season that needed pairing was the one thing the rule excluded, and `pair_depth_target` could
-- never hold it ahead: it was refilled only after its runners had already gone idle.
--
-- So every eligible season takes its turn, in a STABLE order (the season number, which never
-- changes), by the tick index -- this clock runs every 15 s -- modulo how many are eligible. Each of
-- n seasons is picked every n-th tick whatever its queue, which is what "none starves" has to mean.
-- Ordering by anything that moves (pending) would let a season skip or repeat a slot as it moved.
--
-- A SEASON WITH NO ROOM IS NOT ELIGIBLE. `pair_depth_target` is the queue Soma keeps ahead of the
-- fleet; a season already holding it needs no tick, and spending one on it is the waste the old
-- emptiest-first rule was reaching for. That belongs in eligibility, where it costs a season
-- nothing, and not in the ordering, where it cost one everything.
WITH eligible AS (
    SELECT s.id, s.number
      FROM seasons s
     WHERE s.game_id = (SELECT id FROM games WHERE slug = ($1)::text) AND s.closed_at IS NULL
       AND EXISTS (SELECT 1 FROM season_maps sm WHERE sm.season_id = s.id AND sm.enabled)
       AND EXISTS (SELECT 1 FROM model_versions v WHERE v.season_id = s.id AND v.status IN ('active', 'verified'))
       AND (SELECT count(*) FROM matches m WHERE m.season_id = s.id AND m.status = 'pending') < ($2)::int
), turn AS (
    SELECT id, row_number() OVER (ORDER BY number) - 1 AS i, count(*) OVER () AS n
      FROM eligible
)
SELECT id AS season_id
  FROM turn
 WHERE i = (floor(extract(epoch FROM now()) / 15)::bigint % n)
