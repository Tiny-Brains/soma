-- max_in_flight ($8) is the runner's match slots, and admit_slots ($11) is the other role's lane.
-- A runner that does not say (an admitting runner, which claims no match, or one from before either
-- was reported) keeps what its row holds. Saying one once is what marks the row `plays_matches` or
-- `admits`: the lanes pair's idle fill counts, and the machines admitters_up() counts. Both stick,
-- because an exchange that omits one says nothing about it rather than denying it -- and neither is
-- the other's negation, so a runner that has said neither counts for nothing rather than being read
-- as an admitter that has never claimed an admission.
-- `used` stamps the key's last_used_at in the same statement, bucketed to 30 s: this route runs
-- 0.89/s per idle runner, and a separate UPDATE every exchange was a round trip that moved nothing
-- 29 times in 30. The INSERT below reads runner_keys in the same snapshot, before the stamp, which
-- changes nothing it reads.
WITH used AS (
    UPDATE runner_keys SET last_used_at = now()
     WHERE key_hash = ($1)::text AND revoked_at IS NULL
       AND (last_used_at IS NULL OR last_used_at < now() - interval '30 seconds')
)
INSERT INTO runners (key_id, label, engine_digest, node_version, orion_version, ops_budget, arch,
        max_in_flight, match_timeout_ms, seat_concurrency, plays_matches, admits, last_seen_at)
SELECT k.id, btrim(($2)::text),
($3)::text, ($4)::text, ($5)::text, ($6)::bigint, ($7)::text, coalesce(($8)::smallint, 4),
($9)::bigint, ($10)::smallint, ($8)::smallint IS NOT NULL, ($11)::smallint IS NOT NULL, now()
-- live_runner_keys is the one predicate for whose key may start a runner: a platform key of a
-- platform admin, or a season key of an admin of its season (N30). Joining users for role = 'admin'
-- here instead refused every season admin's key, so no season could run a fleet of its own.
FROM live_runner_keys k
WHERE k.key_hash = ($1)::text
AND btrim(($2)::text) <> ''
ON CONFLICT (key_id, label) DO
UPDATE
SET engine_digest = EXCLUDED.engine_digest, node_version = EXCLUDED.node_version, orion_version =
    EXCLUDED.orion_version, ops_budget = EXCLUDED.ops_budget, arch = EXCLUDED.arch, max_in_flight =
    coalesce(($8)::smallint, runners.max_in_flight), match_timeout_ms = coalesce(($9)::bigint,
    runners.match_timeout_ms), seat_concurrency = coalesce(($10)::smallint, runners.seat_concurrency),
    plays_matches = runners.plays_matches OR ($8)::smallint IS NOT NULL,
    admits = runners.admits OR ($11)::smallint IS NOT NULL,
    last_seen_at = now()
