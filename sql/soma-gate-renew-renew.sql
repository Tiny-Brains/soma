-- THE ROW'S OWN LEASE, not the deployment's alone. A runner renews by its own elapsed time, once a
-- third of the lease has passed, and only between turns -- so the lease has to cover that third plus
-- the longest turn the row's terms allow, every seat at its deadline and the step: lease >= 1.5 x
-- (seat_count + 1) x turn_ms. `lease_seconds` is the floor, and the same expression is in
-- soma-gate-claim-row.sql (which sends it on the contract) and soma-gate-start-start.sql.
UPDATE matches m
SET lease_expires_at = now() + (SELECT GREATEST(($2)::int, CEIL(1.5 * (m.seat_count + 1) * e.turn_ms / 1000.0)::int)
        FROM match_execution(m, ($5)::int, ($6)::int, ($7)::int) e) * interval '1 second'
WHERE m.id = ($4)::uuid
AND m.claim_token = ($1)::uuid
AND m.status = 'running'
AND m.played_by = ($3)::uuid
AND EXISTS (SELECT 1
    FROM live_runners lr
    WHERE lr.id = ($3)::uuid)
