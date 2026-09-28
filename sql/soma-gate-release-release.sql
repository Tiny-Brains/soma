-- A RUNNER REFUSED A ROW IT CANNOT PLAY (it has no such model registered yet), so the row goes back
-- to pending and the refusal is counted. It fails MODEL_UNAVAILABLE only when BOTH hold: the count
-- has reached the ceiling, and the refusals have been going on longer than the grace.
--
-- THE GRACE IS THE FLEET'S ALLOWANCE, NOT THE ROW'S AGE, which is why it is measured from
-- `first_refused_at` and not from `created_at`. A runner's lanes poll every five seconds, so a
-- ceiling of five is spent in seconds -- long before a roster clock (every twenty) has registered
-- and activated a new version. Anchored to the row's age instead, a fleet coming up cold against a
-- queue paired an hour ago failed every row on its FIRST refusal, since the grace had passed while
-- nothing was running. That is the ordinary shape of replacing a fleet, the release runbook
-- included. `coalesce(first_refused_at, now())` is what makes the first refusal always start the
-- clock rather than end the row.
WITH c AS (SELECT m.id, m.refusals + 1 >= coalesce(CASE
        WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'refusal_ceiling')::int
        END, ($3)::int)
    AND coalesce(m.first_refused_at, now()) <= now() - ($6)::int * interval '1 second' AS spent
    FROM matches m
    JOIN seasons se ON se.id = m.season_id
    WHERE m.id = ($5)::uuid)
UPDATE matches
SET status = CASE
WHEN c.spent THEN 'failed'
ELSE 'pending'
END::match_status, refusals = refusals + 1, first_refused_at = coalesce(matches.first_refused_at, now()),
    claim_token = NULL, lease_expires_at = NULL, fault_reason
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
