-- THE FIT: a row goes only to a runner whose channel timeout covers what the row will cost --
-- turn_ms x max_turns x the turns' seat batches, plus a tenth for the steps and the gate calls --
-- so a match a node cannot finish inside its deadline is never claimed, reaped and re-claimed
-- for ever; it waits, pending and visible. A runner that reported no timeout (before it was
-- reported) is not bounded.
WITH pick AS MATERIALIZED (SELECT m.id
    FROM matches m
    JOIN live_runners lr ON lr.id = ($5)::uuid
    JOIN seasons se ON se.id = m.season_id
    CROSS JOIN LATERAL match_execution(m, ($6)::int, ($7)::int, ($8)::int) e
    WHERE m.status = 'pending'
    AND m.engine_digest = ($1)::text
    AND m.seat_count <= ($4)::int
    -- THE FLEET POLICY (N30). A SEASON runner (lr.season_id set) claims only its own season's rows,
    -- and only while that season lets its own fleet play (fleet.matches in 'own'|'both'). A PLATFORM
    -- runner (lr.season_id null) claims any season whose policy admits the platform ('platform'|'both').
    -- A season runner never reaches another season, whatever that season's policy says.
    AND CASE WHEN lr.season_id IS NOT NULL
             THEN m.season_id = lr.season_id AND (se.fleet ->> 'matches') IN ('own', 'both')
             ELSE (se.fleet ->> 'matches') IN ('platform', 'both')
        END
    AND (SELECT count(*)
        FROM matches h
        WHERE h.played_by = lr.id
        AND h.status IN ('claimed', 'running')) < lr.max_in_flight
    AND (lr.match_timeout_ms IS NULL OR lr.seat_concurrency IS NULL
         OR e.turn_ms::numeric * e.max_turns * ceil(m.seat_count::numeric / lr.seat_concurrency) * 11
            <= lr.match_timeout_ms::numeric * 10)
    ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.refusals, m.created_at, m.id
    LIMIT 1
    FOR UPDATE OF m SKIP LOCKED)
UPDATE matches m
SET status = 'claimed', claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval
    '1 second', played_by = ($5)::uuid
FROM pick
WHERE m.id = pick.id
