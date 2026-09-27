SELECT json_build_object('runner_id', lr.id, 'key_id', lr.key_id, 'label', lr.label, 'max_in_flight',
        lr.max_in_flight, 'ops_budget', r.ops_budget, 'ops_required', (SELECT min((s.rules -> 'graph'
                    ->> 'adapter_ops_max')::bigint)
        FROM seasons s
        WHERE s.closed_at IS NULL
        AND coalesce((s.rules -> 'graph' ->> 'enabled')::bool, false)
        AND s.rules -> 'graph' ->> 'adapter_ops_max' IS NOT NULL
        -- Only the seasons THIS key reaches (N30): a season key is bounded by its own season, a
        -- platform key by every live season, so ops_required is the ceiling this runner must honour.
        AND (lr.season_id IS NULL OR s.id = lr.season_id))) AS body
FROM live_runners lr
JOIN runners r ON r.id = lr.id
JOIN runner_keys k ON k.id = lr.key_id
WHERE k.key_hash = ($1)::text
AND lr.label = btrim(($2)::text)
