WITH m AS (UPDATE matches
    SET status = 'finished', reason = ($4)::text, turns = ($5)::int, played_ms = GREATEST(0, (EXTRACT(EPOCH
                FROM (now() - ($6)::timestamptz)) * 1000)::int), engine_digest_played = ($7)::text,
        orion_version = ($8)::text, replay_key = ($9)::text, played_at = now(), lease_expires_at =
        NULL
    WHERE id = ($2)::uuid
    AND claim_token = ($1)::uuid
    AND status = 'running'
    AND played_by = ($10)::uuid
    AND EXISTS (SELECT 1
        FROM live_runners lr
        WHERE lr.id = ($10)::uuid)
    AND (SELECT count(DISTINCT v.seat)
        FROM jsonb_to_recordset(($3)::jsonb) AS v (seat smallint)
        WHERE v.seat BETWEEN 0
        AND seat_count - 1) = seat_count
    AND ($7)::text = engine_digest
    AND (SELECT min(v.rank) >= 1
        AND max(v.rank) <= 2 * seat_count
        AND max(v.strikes) <= strike_ceiling
        FROM jsonb_to_recordset(($3)::jsonb) AS v (rank smallint, strikes smallint))
    RETURNING id)
UPDATE match_seats s
SET rank = v.rank, score = v.score, strikes = v.strikes, infer_us_total = v.infer_us_total, infer_us_max
    = v.infer_us_max, infer_turns = v.infer_turns
FROM m, jsonb_to_recordset(($3)::jsonb) AS v (seat smallint, rank smallint, score int, strikes smallint,
        infer_us_total bigint, infer_us_max int, infer_turns int)
WHERE s.match_id = m.id
AND s.seat = v.seat
