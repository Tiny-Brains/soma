-- IS ANYTHING IN FLIGHT AT ALL. Read only when the reap moved nothing: a lease lapses by time, so
-- the reap may skip a tick only while there is no claimed or running row whose lease could lapse.
-- As runner_gate, like the reap itself.
SELECT EXISTS (SELECT 1 FROM matches m WHERE m.status IN ('claimed', 'running')) AS any
