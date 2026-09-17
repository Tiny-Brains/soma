-- The claim, exactly as soma/workflows/soma-runner-claim.json issues it, for pgbench.
--
-- REPLACED 16 SEPTEMBER 2026. This file used to hold the pre-R7 WAVE claim -- two MATERIALIZED
-- CTEs, a resident-weights affinity term in the ORDER BY, and `LIMIT 16` -- and its header named
-- `kalam/workflows/tb-wave-run.json`, a file R7 deleted. So every number this harness produced for
-- months was the cost of a statement the platform does not run. The shipped claim takes ONE row
-- (decision R7: every Ants map is two-player, so a wave of K existed to amortise a batch of two)
-- and now also carries the runner predicates the gate added.
--
-- Bound values arrive as pgbench variables (`-D digest=...`), which substitute textually and carry
-- their own quotes -- pgbench has no :'var' form and no bind protocol here. Nothing else changed.
-- What is measured is the index probe, the in-flight InitPlan and the row lock, which is what a
-- poll costs when it finds nothing and what it costs when it finds a row.
--
-- WHY THE IN-FLIGHT SUBQUERY MATTERS TO THE MEASUREMENT and is not scenery: it is uncorrelated, so
-- the planner evaluates it ONCE per statement as an InitPlan rather than per candidate row. If a
-- future edit accidentally correlates it -- by referencing `m` inside it -- this harness is where
-- that shows up, as a claim whose cost grows with queue depth when it should be flat.
--
-- ROLLED BACK, never committed. The point is the COST of a poll under N concurrent pollers, not the
-- draining of a queue: committing would empty it in the first second and measure an empty table for
-- the rest of the run. SKIP LOCKED still does its real work -- each client locks a different row and
-- releases it at the rollback -- so the contention is genuine.
BEGIN;
WITH pick AS MATERIALIZED (
    SELECT m.id
      FROM matches m
     WHERE m.status = 'pending'
       AND m.engine_digest = :digest
       AND m.seat_count <= :seats
       AND EXISTS (SELECT 1 FROM live_runners lr
                    WHERE lr.id = :runner
                      AND (SELECT count(*) FROM matches h
                            WHERE h.played_by = :runner
                              AND h.status IN ('claimed', 'running')) < lr.max_in_flight)
     ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.created_at, m.id
     LIMIT 1 FOR UPDATE SKIP LOCKED
)
UPDATE matches m
   SET status = 'claimed', claim_token = gen_random_uuid(),
       lease_expires_at = now() + 300 * interval '1 second',
       played_by = :runner
  FROM pick WHERE m.id = pick.id;
ROLLBACK;
