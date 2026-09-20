WITH c AS (SELECT m.id, m.refusals + 1 >= coalesce(CASE
        WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'refusal_ceiling')::int
        END, ($3)::int)
    AND m.created_at <= now() - ($6)::int * interval '1 second' AS spent
    FROM matches m
    JOIN seasons se ON se.id = m.season_id
    WHERE m.id = ($5)::uuid)
UPDATE matches
SET status = CASE
WHEN c.spent THEN 'failed'
ELSE 'pending'
END::match_status, refusals = refusals + 1, claim_token = NULL, lease_expires_at = NULL, fault_reason
    = CASE
WHEN c.spent THEN 'MODEL_UNAVAILABLE'
END, closed_at = CASE
WHEN c.spent THEN now()
END
FROM c
WHERE matches.id = c.id
AND matches.claim_token = ($1)::uuid
AND matches.status = 'claimed'
AND ($2)::boolean
AND matches.played_by = ($4)::uuid
AND EXISTS (SELECT 1
    FROM live_runners lr
    WHERE lr.id = ($4)::uuid)
