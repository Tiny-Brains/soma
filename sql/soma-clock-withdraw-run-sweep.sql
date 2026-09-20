UPDATE matches m
   SET status = 'cancelled', closed_at = now(),
       withdrawn_reason =
           CASE WHEN s.closed_at IS NOT NULL            THEN 'SEASON_CLOSED'
                WHEN m.engine_digest <> s.engine_digest THEN 'ENGINE_RETIRED'
                ELSE (SELECT CASE v.status WHEN 'superseded' THEN 'SUPERSEDED'
                                           WHEN 'rejected'   THEN 'REJECTED'
                                           -- the disable cancels its own queue in the same
                                           -- statement; this is the backstop for a race with it
                                           WHEN 'disabled'   THEN 'BASELINE_DISABLED'
                                           ELSE 'SEAT_LEFT' END
                        FROM match_seats st
                        JOIN model_versions v ON v.id = st.version_id
                       WHERE st.match_id = m.id
                         AND NOT (v.status = 'active'
                               OR (v.status = 'verified' AND v.id = m.trial_version_id))
                       ORDER BY st.seat LIMIT 1)
           END,
       -- The successor is THE SAME ENTRY'S next version. Scoped by owner, as it was before the
       -- entry split, this named an arbitrary sibling entry's version -- telling a competitor
       -- their match was cancelled for "v7" when the version that replaced this seat was v3.
       successor_version_id =
           (SELECT succ.id
              FROM match_seats st
              JOIN model_versions gone ON gone.id = st.version_id AND gone.status = 'superseded'
              JOIN model_versions succ ON succ.model_id = gone.model_id
                              AND succ.season_id = gone.season_id AND succ.status = 'active'
             WHERE st.match_id = m.id
             ORDER BY st.seat LIMIT 1)
  FROM seasons s
 WHERE s.id = m.season_id AND m.status = 'pending'
   AND (s.closed_at IS NOT NULL
     OR m.engine_digest <> s.engine_digest
     OR EXISTS (SELECT 1 FROM match_seats st
                  JOIN model_versions v ON v.id = st.version_id
                 WHERE st.match_id = m.id
                   AND NOT (v.status = 'active'
                         OR (v.status = 'verified' AND v.id = m.trial_version_id))))
