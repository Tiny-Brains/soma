-- THE VALUES THE NEW SCHEMA DERIVES, FOR ROWS THAT PREDATE IT. Run by cutover.sql inside its one
-- transaction, after transfer.sql has copied the data and the schemas have swapped (so `public` is
-- the new schema and `legacy` the release being replaced), and before verify.sql. It is not a step
-- of its own: run cutover.sh.
--
-- THIS RELEASE: SEASON RECORDS. A closed season is now read from its record (season_records,
-- season_standings, season_version_ratings), which the close writes. A season that closed BEFORE
-- this release has none, so it is written here, once, as reason 'backfill' -- and from what the
-- release being replaced SERVED, not from this release's code: each ladder is rendered by that
-- release's own leaderboard statement (legacy-leaderboard.sql, copied verbatim from v0.9.1) run
-- against `legacy`, so the record is the page as it stood, field for field, special cases and all.
--
-- A version's ratings are that release's model_ratings() (legacy.model_ratings, called as pg_temp.legacy_model_ratings) with one
-- correction: a season closed under per-class ratings kept its class rows, and its class tables
-- were frozen from them, but 0.9's model_ratings() still answered the class key from Open -- so a
-- version page disagreed with its own leaderboard. Where a class row exists, the class key is that
-- row, ranked against the class table just recorded, as 0.7.2 showed it.
--
-- A private closed season would render empty (the statement serves the anonymous public), so the
-- cutover refuses one rather than record nothing. Idempotent: a season that has a record is skipped.

SELECT coalesce(string_agg(s.slug, ', '), '') AS private_closed
  FROM seasons s
 WHERE s.closed_at IS NOT NULL AND s.visibility <> 'public'
   AND NOT EXISTS (SELECT 1 FROM season_records r WHERE r.season_id = s.id) \gset
SELECT :'private_closed' = '' AS none_private \gset
\if :none_private
\else
  \echo 'REFUSED: closed private season(s) with no record, which the public leaderboard statement cannot render: ' :'private_closed'
  \quit 3
\endif

-- The release being replaced's own statement, as a function over `legacy`. Its body is the file
-- verbatim inside SELECT x.body FROM (...) x; search_path is pinned so every name in it resolves to
-- what that release served from.
\set legacy_leaderboard `cat /cut/legacy-leaderboard.sql`
SET LOCAL check_function_bodies = off;
SELECT format($f$CREATE FUNCTION pg_temp.legacy_leaderboard(text, text, int, int, float8, text, uuid, uuid)
                 RETURNS json LANGUAGE sql STABLE SET search_path = legacy, pg_catalog AS %L$f$,
              'SELECT x.body FROM (' || :'legacy_leaderboard' || E'\n) x') \gexec
-- And its functions, the same way: called from here, a legacy function's own unqualified names
-- would resolve against the NEW schema.
CREATE FUNCTION pg_temp.legacy_season_json(uuid) RETURNS json LANGUAGE sql STABLE
    SET search_path = legacy, pg_catalog
    AS 'SELECT season_json(s) FROM seasons s WHERE s.id = $1';
CREATE FUNCTION pg_temp.legacy_model_ratings(uuid, float8) RETURNS json LANGUAGE sql STABLE
    SET search_path = legacy, pg_catalog
    AS 'SELECT model_ratings($1, $2)';
RESET check_function_bodies;

-- psql does not substitute a variable inside a DO block's body, so the deploy's settled_sigma rides
-- a transaction-local setting into it.
SELECT set_config('soma.cutover_settled_sigma', :'settled_sigma', true) AS settled_sigma;

DO $records$
DECLARE
  s       record;
  l       ladder;
  cursor_ int;
  page    json;
  n       int;
  deploy_sigma float8 := current_setting('soma.cutover_settled_sigma')::float8;
BEGIN
  FOR s IN SELECT se.id, se.slug, g.slug AS game
             FROM seasons se JOIN games g ON g.id = se.game_id
            WHERE se.closed_at IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM season_records r WHERE r.season_id = se.id)
            ORDER BY se.closed_at
  LOOP
    -- What rated it: every season closed before records was rated by the same tb.rating build,
    -- a962eade, under the same parameters -- soma v0.7.2 through v0.9.1 ship that component byte for
    -- byte, and the parameters are literals in docker/soma.toml.tmpl that no deployment overrides.
    INSERT INTO season_records (season_id, revision, format, reason, columns, summary, rating)
    VALUES (s.id, 1, 1, 'backfill', standings_columns(1), pg_temp.legacy_season_json(s.id),
            jsonb_build_object('plugin', 'tb.rating',
                               'digest', 'sha256:a962eade5d2126b7a08104e7b566ed6ff9183da7cfd445414254ba3d74358e23',
                               'ts_beta', 4.166666666666667, 'ts_tau', 0.08333333333333333,
                               'ts_draw_probability', 0.10, 'prior_mu', 25.0,
                               'prior_sigma', 8.333333333333334, 'settled_sigma', deploy_sigma));

    FOREACH l IN ARRAY enum_range(NULL::ladder) LOOP
      cursor_ := 0;
      LOOP
        page := pg_temp.legacy_leaderboard(s.game, l::text, 200, cursor_, deploy_sigma, s.slug, NULL, NULL);
        INSERT INTO season_standings (season_id, revision, ladder, rank, version_id, owner_id, rating, entry)
        SELECT s.id, 1, l, (e ->> 'rank')::int, (e ->> 'version_id')::uuid, m.owner_id,
               (e ->> 'rating')::float8, e
          FROM json_array_elements(page -> 'entries') AS e
          JOIN models m ON m.id = (e ->> 'model_id')::uuid;
        EXIT WHEN page ->> 'next_cursor' IS NULL;
        cursor_ := (page ->> 'next_cursor')::int;
      END LOOP;
    END LOOP;

    INSERT INTO season_version_ratings (season_id, revision, version_id, ratings)
    SELECT s.id, 1, v.id,
           CASE WHEN c.version_id IS NULL THEN pg_temp.legacy_model_ratings(v.id, deploy_sigma)
                ELSE (pg_temp.legacy_model_ratings(v.id, deploy_sigma)::jsonb
                      || jsonb_build_object(v.weight_class::text, jsonb_build_object(
                           'rating',      c.conservative,
                           'mu',          c.mu,
                           'sigma',       c.sigma,
                           'provisional', c.sigma > deploy_sigma,
                           'matches',     c.matches_played,
                           'rank',  (SELECT count(*) + 1 FROM season_standings st
                                      WHERE st.season_id = s.id AND st.revision = 1 AND st.ladder = v.weight_class
                                        AND (st.rating > c.conservative
                                             OR (st.rating = c.conservative AND st.version_id < v.id))),
                           'field', (SELECT count(*) FROM season_standings st
                                      WHERE st.season_id = s.id AND st.revision = 1 AND st.ladder = v.weight_class)
                                    + CASE WHEN EXISTS (SELECT 1 FROM season_standings st
                                                         WHERE st.season_id = s.id AND st.revision = 1
                                                           AND st.ladder = v.weight_class AND st.version_id = v.id)
                                           THEN 0 ELSE 1 END)))::json END
      FROM model_versions v
      LEFT JOIN ratings c ON c.version_id = v.id AND c.ladder = v.weight_class
     WHERE v.season_id = s.id;

    SELECT count(*) INTO n FROM season_standings st WHERE st.season_id = s.id;
    RAISE NOTICE 'recorded %: % standings rows, % versions', rpad(s.slug, 24), n,
      (SELECT count(*) FROM season_version_ratings vr WHERE vr.season_id = s.id);
  END LOOP;
END
$records$;
