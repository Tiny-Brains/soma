UPDATE matches
SET status = CASE
WHEN lapses + 1 >= 3 THEN 'failed'
ELSE 'pending'
END::match_status, lapses = lapses + 1, claim_token = NULL, lease_expires_at = NULL, fault_reason
    = CASE
WHEN lapses + 1 >= 3 THEN 'LEASE_LAPSED'
END, closed_at = CASE
WHEN lapses + 1 >= 3 THEN now()
END
WHERE status IN ('claimed', 'running')
AND lease_expires_at < now()
