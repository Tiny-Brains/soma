-- Race 2, prober: a newer occurrence (10:02/1) claims the fence while the live fold holds FOR SHARE.
-- Expected: the claim blocks until the holder commits, then UPDATE 1. The fold's write landed under
-- the fence that was current when it took the lock, which finding 1 says is also correct.
\set ON_ERROR_STOP off
\pset footer off
\timing on
\echo 'prober: claiming fence 10:02/1 (expect UPDATE 1 after a wait)'
EXECUTE c_fence ('2026-09-07 10:02:00+00', 1);
\timing off
SELECT key, scheduled_for, attempt FROM clocks WHERE key = 'count';
SELECT seed, status, rated_seq FROM matches WHERE seed = 52;
