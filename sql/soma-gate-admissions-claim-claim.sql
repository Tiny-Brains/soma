WITH pick AS MATERIALIZED (
    SELECT a.version_id
    FROM admissions a
    JOIN model_versions v ON v.id = a.version_id
    AND v.status = 'testing'
    JOIN seasons se ON se.id = v.season_id
    JOIN live_runners lr ON lr.id = ($1)::uuid
    WHERE a.report IS NULL
    AND (a.lease_expires_at IS NULL
        OR a.lease_expires_at < now())
    AND a.attempts < ($4)::int
    -- THE FLEET POLICY, on the version's season (N30). A SEASON admitting runner takes only its own
    -- season's admissions, and only while fleet.admissions in 'own'|'both'; a PLATFORM admitting
    -- runner takes any season's under 'platform'|'both'. The admission reaches its season's own
    -- admitting runner, the platform's, or either -- the same predicate as the match claim.
    AND CASE WHEN lr.season_id IS NOT NULL
             THEN v.season_id = lr.season_id AND (se.fleet ->> 'admissions') IN ('own', 'both')
             ELSE (se.fleet ->> 'admissions') IN ('platform', 'both')
        END
    ORDER BY a.prepared_at, a.version_id
    LIMIT 1
    FOR UPDATE OF a SKIP LOCKED)
UPDATE admissions a
SET runner_id = ($1)::uuid, claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval
    '1 second', attempts = a.attempts + 1
FROM pick
WHERE a.version_id = pick.version_id
