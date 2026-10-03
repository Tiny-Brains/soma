WITH live AS (
    SELECT s.id
      FROM seasons s
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL
       -- closure.policy 'admin' waits for the request and never settles itself; 'settle' and
       -- 'deadline' both reach the settled test, and 'deadline' additionally gives up waiting
       -- once settle_grace_days have passed since the window closed. 'finals' never settles
       -- itself either: it waits for the admin to start the finals.
       --
       -- THE FINALS DECIDE, WHATEVER THE POLICY, once an admin has scheduled them: the season
       -- closes when they are done -- started, every entry at its number of games -- and nothing
       -- is left in flight to fold after the podium is frozen; and no settled test closes it before
       -- then. A request to close still wins over both, which is how an admin ends finals that
       -- cannot finish (an entry with nobody left to play).
       -- A request still waits for the fold: nothing `finished` and uncounted, so the record it
       -- writes holds every match played before it (count folds within the minute).
       AND (  (s.close_requested_at IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM matches m WHERE m.season_id = s.id AND m.status = 'finished'))
         OR (coalesce((SELECT f.done FROM season_finals(s.id) f), false)
             AND NOT EXISTS (SELECT 1 FROM matches m
                              WHERE m.season_id = s.id
                                AND m.status IN ('claimed', 'running', 'finished')))
         OR (s.submissions_close_at <= now()
             AND coalesce(s.rules -> 'closure' ->> 'policy', 'settle') NOT IN ('admin', 'finals')
             AND NOT EXISTS (SELECT 1 FROM season_finals(s.id))
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
                               JOIN models re ON re.id = v.model_id AND re.retired_at IS NULL
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
), unplayed AS (
    -- A round still waiting when the season closes never starts, and its countdown, if posted,
    -- ends now rather than counting down to nothing.
    UPDATE season_rounds r
       SET cancelled_at = now()
      FROM closed
     WHERE r.season_id = closed.id AND r.applied_at IS NULL AND r.cancelled_at IS NULL
 RETURNING r.n
), silenced AS (
    UPDATE announcements a
       SET ends_at = now()
      FROM closed
     WHERE a.season_id = closed.id AND a.source IS NOT NULL
       AND (a.ends_at IS NULL OR a.ends_at > now())
 RETURNING a.id
), podium AS (
    -- THE PODIUM, FROZEN IN THE STATEMENT THAT CLOSES: first to third on every ladder, one place
    -- per owner, no baselines (podium_of). It reads the season's `active` versions, which neither
    -- sibling CTE touches, so the snapshot every CTE shares is the final standing.
    INSERT INTO season_podium (season_id, ladder, place, version_id, owner_id, rating)
    SELECT closed.id, l.ladder, p.place, p.version_id, p.owner_id, p.rating
      FROM closed
     CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
     CROSS JOIN LATERAL podium_of(closed.id, l.ladder) p
), recorded AS (
    -- THE RECORD, IN THE SAME STATEMENT: what the season shows, rendered once by the live code and
    -- read from then on instead of it (season_records). Same snapshot as the podium, so the record,
    -- the podium and the close cannot disagree. The summary is the season as it reads once closed
    -- (season_closing_summary); `rating` pins what rated it: the plugin's digest ($4, this node's
    -- [vars] rating_digest) and every parameter count passes it ($5-$9), and settled_sigma ($2).
    INSERT INTO season_records (season_id, revision, format, reason, columns, summary, rating)
    SELECT s.id, 1, 1, 'close', standings_columns(1), season_closing_summary(s),
           jsonb_build_object('plugin', 'tb.rating', 'digest', nullif(($4)::text, ''),
                              'ts_beta', ($5)::float8, 'ts_tau', ($6)::float8,
                              'ts_draw_probability', ($7)::float8, 'prior_mu', ($8)::float8,
                              'prior_sigma', ($9)::float8, 'settled_sigma', ($2)::float8)
      FROM closed JOIN seasons s ON s.id = closed.id
), standings AS (
    INSERT INTO season_standings (season_id, revision, ladder, rank, version_id, owner_id, rating, entry)
    SELECT closed.id, 1, l.ladder, st.rank, st.version_id, st.owner_id, st.rating, st.entry
      FROM closed
     CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
     CROSS JOIN LATERAL ladder_standings(closed.id, l.ladder, ($2)::float8) st
), version_ratings AS (
    INSERT INTO season_version_ratings (season_id, revision, version_id, ratings)
    SELECT closed.id, 1, v.id, model_ratings(v.id, ($2)::float8)
      FROM closed JOIN model_versions v ON v.season_id = closed.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM closed WHERE c.key = 'roster'
