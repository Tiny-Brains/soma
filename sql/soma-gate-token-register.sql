-- max_in_flight ($8) is the runner's match slots. A runner that does not say (an admitting runner,
-- which claims no match, or one from before it was reported) keeps what its row holds. Saying it
-- once is what marks the row `plays_matches`, the lanes pair's idle fill counts.
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
        max_in_flight, match_timeout_ms, seat_concurrency, plays_matches, last_seen_at)
SELECT k.id, btrim(($2)::text),
($3)::text, ($4)::text, ($5)::text, ($6)::bigint, ($7)::text, coalesce(($8)::smallint, 4),
($9)::bigint, ($10)::smallint, ($8)::smallint IS NOT NULL, now()
FROM runner_keys k
JOIN users u ON u.id = k.user_id
AND u.role = 'admin'
WHERE k.key_hash = ($1)::text
AND k.revoked_at IS NULL
AND btrim(($2)::text) <> ''
ON CONFLICT (key_id, label) DO
UPDATE
SET engine_digest = EXCLUDED.engine_digest, node_version = EXCLUDED.node_version, orion_version =
    EXCLUDED.orion_version, ops_budget = EXCLUDED.ops_budget, arch = EXCLUDED.arch, max_in_flight =
    coalesce(($8)::smallint, runners.max_in_flight), match_timeout_ms = coalesce(($9)::bigint,
    runners.match_timeout_ms), seat_concurrency = coalesce(($10)::smallint, runners.seat_concurrency),
    plays_matches = runners.plays_matches OR ($8)::smallint IS NOT NULL,
    last_seen_at = now()
