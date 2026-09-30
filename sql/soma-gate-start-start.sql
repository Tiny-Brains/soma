-- claimed -> running, on the token, and THE LEASE IS RESET TO THE ROW'S OWN: the runner's renew
-- clock starts before it asks for this, so from here on it never runs ahead of the database's. Same
-- expression as soma-gate-renew-renew.sql, which says why it is what it is.
UPDATE matches m
SET status = 'running', lease_expires_at = now() + (SELECT GREATEST(($4)::int, CEIL(1.5 * (m.seat_count
            + 1) * e.turn_ms / 1000.0)::int)
        FROM match_execution(m, ($5)::int, ($6)::int, ($7)::int) e) * interval '1 second'
WHERE m.id = ($3)::uuid
AND m.claim_token = ($1)::uuid
AND m.status = 'claimed'
AND m.played_by = ($2)::uuid
AND EXISTS (SELECT 1
    FROM live_runners lr
    WHERE lr.id = ($2)::uuid)
