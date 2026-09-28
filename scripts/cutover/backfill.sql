-- THE VALUES THE NEW SCHEMA DERIVES, FOR ROWS THAT PREDATE IT. Run by cutover.sql inside its one
-- transaction, after transfer.sql has copied the data and the schemas have swapped (so `public` is
-- the new schema), and before verify.sql. It is not a step of its own: run cutover.sh.
--
-- Every statement is idempotent: a second run writes the same values. It sends no notification --
-- a medal for a season that closed weeks ago is news to nobody. Past matches' last frames are not
-- here: they need each replay decoded, which backfill-frames.sh does once the new node serves. Each value is computed by the function the live path
-- uses (match_sort_keys, season_map_name, podium_of, ladder_at, memory_price), so a backfilled row
-- and a row written tomorrow cannot disagree. This directory goes once production has been cut over.


-- ONE RATED LADDER (this release). Production was copied from the dual-ladder schema, so transfer.sql
-- brought per-class `ratings`, `rating_events` and `ladder_snapshots`, and matches whose `ladders`
-- array still carries a class. A weight class is now a filtered VIEW of Open, so those class rows are
-- dead weight the new reads never touch: normalise every rated match's array to {open} (trials keep
-- {}), and drop the class ratings, events and snapshots. The Open rows -- the real ladder -- and the
-- frozen per-class `season_podium` (a view label, still wanted) are left untouched. Idempotent: a
-- second run finds nothing left to change.
UPDATE matches SET ladders = ARRAY['open']::ladder[]
 WHERE 'open' = ANY (ladders) AND ladders <> ARRAY['open']::ladder[];
DELETE FROM rating_events    WHERE ladder <> 'open';
DELETE FROM ratings          WHERE ladder <> 'open';
DELETE FROM ladder_snapshots WHERE ladder <> 'open';

-- Who may see a match: what finish and a trial's pass would have set. A trial is public when its
-- candidate went public.
UPDATE matches m SET listed = true
 WHERE NOT m.listed AND m.status IN ('finished', 'rated')
   AND (m.trial_version_id IS NULL
        OR EXISTS (SELECT 1 FROM model_versions c
                    WHERE c.id = m.trial_version_id AND c.status IN ('active', 'superseded')));

-- The sort keys. match_sort_keys() reads each seat's pre-fold rating from rating_events.*_before,
-- which is the number the fold would have read; a trial has no upset.
UPDATE matches m
   SET (margin, upset) = (SELECT k.margin, CASE WHEN m.trial_version_id IS NULL THEN k.upset END
                            FROM match_sort_keys(m.id) k)
 WHERE m.status = 'rated' AND m.margin IS NULL AND m.upset IS NULL;

-- Each version's record per ladder, as the fold keeps it: a win is first alone, a draw a shared
-- first, anything else a loss. Set rather than added.
UPDATE ratings r
   SET wins = c.w, draws = c.d, losses = c.l
  FROM (SELECT ms.version_id, l.ladder,
               count(*) FILTER (WHERE ms.rank = 1 AND f.n = 1) AS w,
               count(*) FILTER (WHERE ms.rank = 1 AND f.n > 1) AS d,
               count(*) FILTER (WHERE ms.rank IS DISTINCT FROM 1) AS l
          FROM matches m
          JOIN match_seats ms ON ms.match_id = m.id
          JOIN model_versions v ON v.id = ms.version_id
         CROSS JOIN LATERAL unnest(m.ladders) AS l (ladder)
         CROSS JOIN LATERAL (SELECT count(*) AS n FROM match_seats x
                              WHERE x.match_id = m.id AND x.rank = 1) f
         WHERE m.status = 'rated' AND m.trial_version_id IS NULL
           AND (l.ladder = 'open' OR l.ladder = v.weight_class)
         GROUP BY ms.version_id, l.ladder) c
 WHERE r.version_id = c.version_id AND r.ladder = c.ladder;

-- The counts the fold moves: rated matches, trials excluded, per board and per season, and each
-- board's newest. Set rather than added, so a second run writes the same numbers.
UPDATE season_maps sm
   SET matches = c.n, latest_match_id = c.latest
  FROM (SELECT m.season_map_id, count(*) AS n,
               (array_agg(m.id ORDER BY m.played_at DESC, m.id DESC))[1] AS latest
          FROM matches m WHERE m.status = 'rated' AND m.trial_version_id IS NULL
         GROUP BY m.season_map_id) c
 WHERE sm.id = c.season_map_id;
UPDATE seasons s
   SET matches_played = c.n
  FROM (SELECT m.season_id, count(*) AS n
          FROM matches m WHERE m.status = 'rated' AND m.trial_version_id IS NULL
         GROUP BY m.season_id) c
 WHERE s.id = c.season_id;

-- The board fields, only where the stored file agrees with its name -- the upload's own rule. A
-- board named before the rule keeps null fields, and the query below lists them.
UPDATE season_maps sm
   SET size = n.n ->> 'size', terrain = n.n ->> 'terrain', hills = (n.n ->> 'hills')::smallint
  FROM (SELECT s.id, season_map_name(s.map_id) AS n, season_map_header(s.board) AS h FROM season_maps s) n
 WHERE n.id = sm.id AND sm.size IS NULL
   AND n.h IS NOT NULL AND season_map_name_problem(n.h) IS NULL;

-- What each admitted version's memory costs on the largest board, as admission prices it now: 0 for
-- a manifest that declares none, which should be every one (the query at the end lists the rest).
UPDATE model_versions v
   SET memory_bytes = coalesce((SELECT p.bytes_max
                                  FROM games g, memory_price(v.manifest::jsonb, g.manifest #> '{limits,boards}', NULL) p
                                 WHERE g.id = v.game_id), 0)
 WHERE v.memory_bytes IS NULL AND v.manifest IS NOT NULL;

-- The podium of every season already closed, as the close would have written it.
INSERT INTO season_podium (season_id, ladder, place, version_id, owner_id, rating)
SELECT s.id, l.ladder, p.place, p.version_id, p.owner_id, p.rating
  FROM seasons s
 CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
 CROSS JOIN LATERAL podium_of(s.id, l.ladder) p
 WHERE s.closed_at IS NOT NULL
ON CONFLICT (season_id, ladder, place) DO NOTHING;

-- Every hour of every season's Open ladder, as the withdraw clock would have written it live: from
-- the first hour after it opened to its close, or now. One rated ladder, so one row per hour (a class
-- series filters this Open row); ladder_at() per hour, about 24 calls a day of season, each a few ms.
INSERT INTO ladder_snapshots (season_id, ladder, at, version_ids, ratings)
SELECT s.id, 'open'::ladder, h.at, coalesce(f.version_ids, '{}'), coalesce(f.ratings, '{}')
  FROM seasons s
 CROSS JOIN LATERAL generate_series(date_trunc('hour', s.submissions_open_at) + interval '1 hour',
                                    date_trunc('hour', coalesce(s.closed_at, now())),
                                    interval '1 hour') AS h (at)
 CROSS JOIN LATERAL (SELECT array_agg(a.version_id ORDER BY a.rank) AS version_ids,
                            array_agg(a.conservative::real ORDER BY a.rank) AS ratings
                       FROM ladder_at(s.id, 'open'::ladder, h.at) a) f
ON CONFLICT (season_id, ladder, at) DO NOTHING;

\echo '--- what the backfill wrote'
SELECT count(*) FILTER (WHERE margin IS NOT NULL) AS with_margin,
       count(*) FILTER (WHERE upset IS NOT NULL)  AS with_upset,
       count(*) FILTER (WHERE listed)             AS listed,
       count(*) FILTER (WHERE status = 'rated')   AS rated
  FROM matches;
SELECT se.slug AS season, se.matches_played, (SELECT count(*) FROM ladder_snapshots x WHERE x.season_id = se.id) AS snapshots
  FROM seasons se ORDER BY se.slug;
SELECT se.slug AS season, count(*) AS podium_places
  FROM season_podium sp JOIN seasons se ON se.id = sp.season_id GROUP BY se.slug ORDER BY se.slug;
\echo '--- boards that keep null fields: off the name pattern, or disagreeing with their file'
SELECT se.slug AS season, sm.map_id FROM season_maps sm JOIN seasons se ON se.id = sm.season_id
 WHERE sm.size IS NULL ORDER BY se.slug, sm.map_id;
\echo '--- versions that declare a memory output (expect no rows: each would gain memory mid-season when the runners carry it)'
SELECT se.slug AS season, v.id AS version_id, v.status, v.memory_bytes
  FROM model_versions v JOIN seasons se ON se.id = v.season_id
 WHERE v.memory_bytes > 0 ORDER BY se.slug, v.id;
\echo '--- the rating chain: a version whose matches_played is below its last event would fail every fold (expect no rows)'
SELECT r.version_id, r.ladder, r.matches_played, max(e.seq) AS last_seq
  FROM ratings r JOIN rating_events e ON e.version_id = r.version_id AND e.ladder = r.ladder
 GROUP BY r.version_id, r.ladder, r.matches_played
HAVING r.matches_played < max(e.seq);
