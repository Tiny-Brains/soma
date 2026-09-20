WITH target AS (
    SELECT v.id, v.weight_class, se.rules
    FROM model_versions v
    JOIN models e ON e.id = v.model_id
    JOIN users u ON u.id = e.owner_id
    AND u.role = 'baseline'
    JOIN seasons se ON se.id = v.season_id
    JOIN games g ON g.id = se.game_id
    WHERE g.slug = ($1)::text
    AND se.slug = ($2)::text
    AND lower(u.handle) = lower('baseline.' || ($3)::text)
    AND se.closed_at IS NULL
    AND v.status = CASE
    WHEN ($4)::boolean THEN 'disabled'::model_status
    ELSE 'active'::model_status
    END
    FOR UPDATE OF v ),
flipped AS (
    UPDATE model_versions v
    SET status = CASE
    WHEN ($4)::boolean THEN 'active'::model_status
    ELSE 'disabled'::model_status
    END
    FROM target
    WHERE v.id = target.id
    RETURNING v.id, v.weight_class, target.rules ),
rated AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma)
    SELECT f.id, l.ladder, coalesce((f.rules -> 'rating' ->> 'prior_mu')::float8, ($6)::float8), coalesce((f.rules
                -> 'rating' ->> 'prior_sigma')::float8, ($7)::float8)
    FROM flipped f
    CROSS JOIN LATERAL (VALUES (f.weight_class), ('open'::ladder)) AS l (ladder)
    WHERE ($4)::boolean
    ON CONFLICT (version_id, ladder) DO NOTHING
    RETURNING version_id, ladder, mu, sigma ),
seeded AS (
    INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
    SELECT version_id, ladder, 0, mu, sigma
    FROM rated
    ON CONFLICT (version_id, ladder, seq) DO NOTHING
    RETURNING 1 ),
cancelled AS (
    UPDATE matches m
    SET status = 'cancelled', withdrawn_reason = 'BASELINE_DISABLED', closed_at = now()
    FROM flipped
    WHERE NOT ($4)::boolean
    AND m.status = 'pending'
    AND EXISTS (SELECT 1
        FROM match_seats s
        WHERE s.match_id = m.id
        AND s.version_id = flipped.id)
    RETURNING m.id ),
bump AS (
    UPDATE clocks c
    SET epoch = c.epoch + 1, updated_at = now()
    FROM flipped
    WHERE c.key = 'roster'
    RETURNING c.epoch )
INSERT INTO baseline_events (version_id, action, by_user, cancelled)
SELECT flipped.id, CASE
WHEN ($4)::boolean THEN 'enable'
ELSE 'disable'
END, ($5)::uuid, (SELECT count(*)
    FROM cancelled)
FROM flipped
