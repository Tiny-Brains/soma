-- A ROW GOES TO ANY RUNNER OF ITS ENGINE, AND THE SEASON'S TERMS ARE WHAT IT IS PLAYED UNDER. This
-- statement narrows by the digest, the fleet policy and the runner's own lanes -- and by nothing a
-- runner reports about how long it is willing to play or how many seats it will take. It used to:
-- the claim priced the row at turn_ms x max_turns x the seat batches, plus a tenth, against the
-- runner's channel timeout, and took `seat_count` from the request as a ceiling. Both were a runner
-- prescribing the match. A node whose deadline was short for a board did not play that board more
-- slowly, it removed it from the ladder: the row stayed pending for ever (the reap only touches
-- claimed and running), pair skipped the board, and the season played its narrow boards in silence.
-- Kalam now covers the widest match these rules can declare -- its seat width is the cartridge's
-- envelope and its channel timeout is sized from soma's own rule ceilings, checked by web's
-- configs.sh -- so there is nothing left here to filter on. The terms ride the row, in
-- `soma-gate-claim-row.sql`.
WITH pick AS MATERIALIZED (SELECT m.id
    FROM matches m
    JOIN live_runners lr ON lr.id = ($4)::uuid
    JOIN seasons se ON se.id = m.season_id
    WHERE m.status = 'pending'
    AND m.engine_digest = ($1)::text
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
    ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.refusals, m.created_at, m.id
    LIMIT 1
    FOR UPDATE OF m SKIP LOCKED)
UPDATE matches m
SET status = 'claimed', claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval
    '1 second', played_by = ($4)::uuid
FROM pick
WHERE m.id = pick.id
