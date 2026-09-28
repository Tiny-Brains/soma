WITH live AS (
    SELECT s.id
      FROM seasons s
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL
       -- closure.policy 'admin' waits for the request and never settles itself; 'settle' and
       -- 'deadline' both reach the settled test, and 'deadline' additionally gives up waiting
       -- once settle_grace_days have passed since the window closed.
       AND (s.close_requested_at IS NOT NULL
         OR (s.submissions_close_at <= now()
             AND coalesce(s.rules -> 'closure' ->> 'policy', 'settle') <> 'admin'
             AND (
                (coalesce(s.rules -> 'closure' ->> 'policy', 'settle') = 'deadline'
                 AND s.submissions_close_at
                     + make_interval(days => coalesce((s.rules -> 'closure' ->> 'settle_grace_days')::int, 0))
                     <= now())
             OR (
             NOT EXISTS (SELECT 1 FROM model_versions v
                              WHERE v.season_id = s.id AND v.status IN ('testing', 'verified'))
             AND NOT EXISTS (SELECT 1 FROM matches m
                              WHERE m.season_id = s.id
                                AND m.status NOT IN ('rated', 'cancelled', 'failed'))
             -- Settled is now judged on the one rated ladder, Open: no active version is missing its
             -- Open row, still above settled_sigma, or short of its placement burst.
             AND NOT EXISTS (SELECT 1
                               FROM model_versions v
                               LEFT JOIN ratings r ON r.version_id = v.id AND r.ladder = 'open'
                              WHERE v.season_id = s.id AND v.status = 'active'
                                AND (r.version_id IS NULL
                                  OR r.sigma > coalesce((s.rules -> 'rating' ->> 'settled_sigma')::float8,
                                                        ($2)::float8)
                                  OR r.matches_played < coalesce((s.rules -> 'pairing' ->> 'burst')::int,
                                                                 ($3)::int)))))))
), closed AS (
    UPDATE seasons s SET closed_at = now()
      FROM live WHERE s.id = live.id
 RETURNING s.id
), rejected AS (
    UPDATE model_versions md SET status = 'rejected', reject_reason = 'SEASON_CLOSED'
      FROM closed
     WHERE md.season_id = closed.id AND md.status IN ('testing', 'verified')
 RETURNING md.id
), withdrawn AS (
    UPDATE matches m
       SET status = 'cancelled', withdrawn_reason = 'SEASON_CLOSED', closed_at = now()
      FROM closed
     WHERE m.season_id = closed.id AND m.status = 'pending'
 RETURNING m.id
), podium AS (
    -- THE PODIUM, FROZEN IN THE STATEMENT THAT CLOSES: first to third on every ladder, one place
    -- per owner, no baselines (podium_of). It reads the season's `active` versions, which neither
    -- sibling CTE touches, so the snapshot every CTE shares is the final standing.
    INSERT INTO season_podium (season_id, ladder, place, version_id, owner_id, rating)
    SELECT closed.id, l.ladder, p.place, p.version_id, p.owner_id, p.rating
      FROM closed
     CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
     CROSS JOIN LATERAL podium_of(closed.id, l.ladder) p
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM closed WHERE c.key = 'roster'
