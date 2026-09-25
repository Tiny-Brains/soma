-- THE REDESIGN'S PRODUCTION CUTOVER. `bootstrap` refuses a database built from other migration
-- bytes, and this release rewrites them, so production is rebuilt once and its data restored:
--
--   0. Before anything stops, on production:
--        CREATE TEMP TABLE lz4_check (j jsonb COMPRESSION lz4);   -- must succeed, or bootstrap fails
--        SELECT map_id FROM season_maps WHERE map_id !~ '^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$';
--        SELECT slug FROM seasons WHERE closed_at IS NOT NULL;
--      The first list is the boards that keep null size, terrain and hills; the second is what the
--      podium backfill covers. Take `gcloud sql backups create --instance tinybrains-pg`.
--   1. Close the season, or stop the runners and the clocks. A season boundary is cheapest.
--   2. `pg_dump --data-only` every existing table.
--   3. Rebuild from the new migrations and restore. The new tables start empty.
--   4. Run this file, once, as the owner, BEFORE the runners and the clocks come back:
--        psql "$SOMA_DB_URL" -v ON_ERROR_STOP=1 -f scripts/backfill-redesign.sql
--   5. Read what it prints: the rating chain (ratings.matches_played against rating_events' last
--      seq, which a restore must keep) must list no rows, and the row counts must match the dump.
--
-- Every statement is idempotent: a second run writes the same values. It sends no notification --
-- a medal for a season that closed weeks ago is news to nobody -- and past matches have no last
-- frame, so their cards rest on turn zero. Each value is computed by the function the live path
-- uses (match_sort_keys, season_map_name, podium_of, ladder_at), so a backfilled row and a row
-- written tomorrow cannot disagree. This file goes once production has been cut over.

\set ON_ERROR_STOP on
BEGIN;

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

-- The podium of every season already closed, as the close would have written it.
INSERT INTO season_podium (season_id, ladder, place, version_id, owner_id, rating)
SELECT s.id, l.ladder, p.place, p.version_id, p.owner_id, p.rating
  FROM seasons s
 CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
 CROSS JOIN LATERAL podium_of(s.id, l.ladder) p
 WHERE s.closed_at IS NOT NULL
ON CONFLICT (season_id, ladder, place) DO NOTHING;

-- Every hour of every season's ladders, as the withdraw clock would have written them live: from
-- the first hour after it opened to its close, or now. ladder_at() per hour and ladder, so this is
-- the slow statement -- about 6 x 24 calls a day of season, each a few ms at today's field.
INSERT INTO ladder_snapshots (season_id, ladder, at, version_ids, ratings)
SELECT s.id, l.ladder, h.at, coalesce(f.version_ids, '{}'), coalesce(f.ratings, '{}')
  FROM seasons s
 CROSS JOIN LATERAL generate_series(date_trunc('hour', s.submissions_open_at) + interval '1 hour',
                                    date_trunc('hour', coalesce(s.closed_at, now())),
                                    interval '1 hour') AS h (at)
 CROSS JOIN unnest(enum_range(NULL::ladder)) AS l (ladder)
 CROSS JOIN LATERAL (SELECT array_agg(a.version_id ORDER BY a.rank) AS version_ids,
                            array_agg(a.conservative::real ORDER BY a.rank) AS ratings
                       FROM ladder_at(s.id, l.ladder, h.at) a) f
ON CONFLICT (season_id, ladder, at) DO NOTHING;

COMMIT;

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
\echo '--- the rating chain: a version whose matches_played is below its last event would fail every fold (expect no rows)'
SELECT r.version_id, r.ladder, r.matches_played, max(e.seq) AS last_seq
  FROM ratings r JOIN rating_events e ON e.version_id = r.version_id AND e.ladder = r.ladder
 GROUP BY r.version_id, r.ladder, r.matches_played
HAVING r.matches_played < max(e.seq);
