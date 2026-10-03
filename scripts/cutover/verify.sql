-- WHAT MUST HAVE BEEN KEPT. Run by cutover.sql inside its one transaction, last, after backfill.sql.
-- Every check raises, and a raise rolls the whole cutover back: the database is then exactly as it
-- was. It prints counts, never values.
--
--   1. Every legacy table against its copy, every column the two share, cast to text, both ways
--      (EXCEPT ALL): this release rewrites no existing value, so any difference is a loss.
--   2. Every closed season has exactly one record, and every one of its versions a ratings row.
--   3. THE PAGES. For every season and every ladder, this release's leaderboard statement (the
--      image's, leaderboard.sql) answers the same `total`, `round` and `entries` as the release
--      being replaced (legacy-leaderboard.sql over `legacy`): a closed season from its record, a
--      live one through ladder_standings(). Compared as jsonb, every page.
--   4. A live season's versions: model_ratings() answers what legacy.model_ratings() did. A closed
--      season's answers from its record; only a class key backed by a frozen class row may differ.
--   5. The seal is installed.
--   6. Every season document (season_json) reads as before.

DO $kept$
DECLARE
  t     record;
  diff  bigint;
BEGIN
  FOR t IN
    SELECT o.table_name,
           string_agg(format('%I::text', o.column_name), ', ' ORDER BY o.ordinal_position) AS cols
      FROM information_schema.columns o
      JOIN information_schema.columns n
        ON n.table_schema = 'public' AND n.table_name = o.table_name AND n.column_name = o.column_name
      JOIN information_schema.tables x
        ON x.table_schema = 'legacy' AND x.table_name = o.table_name AND x.table_type = 'BASE TABLE'
     WHERE o.table_schema = 'legacy' AND o.table_name <> 'soma_schema'
     GROUP BY o.table_name
  LOOP
    EXECUTE format('SELECT (SELECT count(*) FROM (SELECT %1$s FROM legacy.%2$I EXCEPT ALL SELECT %1$s FROM public.%2$I) a)
                         + (SELECT count(*) FROM (SELECT %1$s FROM public.%2$I EXCEPT ALL SELECT %1$s FROM legacy.%2$I) b)',
                   t.cols, t.table_name) INTO diff;
    IF diff <> 0 THEN
      RAISE EXCEPTION 'verify: % differs from the release it replaces in % row(s)', t.table_name, diff;
    END IF;
  END LOOP;
  RAISE NOTICE 'verify: every legacy table is kept cell for cell';
END
$kept$;

DO $records$
DECLARE bad text;
BEGIN
  SELECT string_agg(s.slug, ', ') INTO bad FROM seasons s
   WHERE s.closed_at IS NOT NULL
     AND (SELECT count(*) FROM season_records r WHERE r.season_id = s.id) <> 1;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'verify: closed season(s) without exactly one record: %', bad;
  END IF;
  SELECT string_agg(s.slug, ', ') INTO bad FROM seasons s
   WHERE s.closed_at IS NOT NULL
     AND EXISTS (SELECT 1 FROM model_versions v WHERE v.season_id = s.id
                  AND NOT EXISTS (SELECT 1 FROM season_version_ratings vr
                                   WHERE vr.season_id = s.id AND vr.version_id = v.id));
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'verify: closed season(s) with a version missing from the record: %', bad;
  END IF;
  RAISE NOTICE 'verify: % closed season(s), each with one record', (SELECT count(*) FROM seasons WHERE closed_at IS NOT NULL);
END
$records$;

-- This release's statement, as a function over the new schema, beside the legacy one backfill.sql made.
\set new_leaderboard `cat /cut/leaderboard.sql`
SET LOCAL check_function_bodies = off;
SELECT format($f$CREATE FUNCTION pg_temp.new_leaderboard(text, text, int, int, float8, text, uuid, uuid)
                 RETURNS json LANGUAGE sql STABLE SET search_path = public, pg_catalog AS %L$f$,
              'SELECT x.body FROM (' || :'new_leaderboard' || E'\n) x') \gexec
RESET check_function_bodies;

DO $pages$
DECLARE
  s       record;
  l       ladder;
  cursor_ int;
  a       json;
  b       json;
  pages   int := 0;
  deploy_sigma float8 := current_setting('soma.cutover_settled_sigma')::float8;
BEGIN
  FOR s IN SELECT se.slug, g.slug AS game FROM seasons se JOIN games g ON g.id = se.game_id
            WHERE se.visibility = 'public'
  LOOP
    FOREACH l IN ARRAY enum_range(NULL::ladder) LOOP
      cursor_ := 0;
      LOOP
        a := pg_temp.legacy_leaderboard(s.game, l::text, 200, cursor_, deploy_sigma, s.slug, NULL, NULL);
        b := pg_temp.new_leaderboard(s.game, l::text, 200, cursor_, deploy_sigma, s.slug, NULL, NULL);
        IF (a -> 'entries')::jsonb IS DISTINCT FROM (b -> 'entries')::jsonb
           OR (a ->> 'total') IS DISTINCT FROM (b ->> 'total')
           OR (a -> 'round')::jsonb IS DISTINCT FROM (b -> 'round')::jsonb
           OR (a ->> 'next_cursor') IS DISTINCT FROM (b ->> 'next_cursor') THEN
          RAISE EXCEPTION 'verify: the % leaderboard of % reads differently from the release it replaces (page at %)',
            l, s.slug, cursor_;
        END IF;
        pages := pages + 1;
        EXIT WHEN a ->> 'next_cursor' IS NULL;
        cursor_ := (a ->> 'next_cursor')::int;
      END LOOP;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'verify: % leaderboard page(s) read the same as the release they replace', pages;
END
$pages$;

DO $versions$
DECLARE
  live_bad   bigint;
  closed_bad bigint;
  corrected  bigint;
  deploy_sigma float8 := current_setting('soma.cutover_settled_sigma')::float8;
BEGIN
  SELECT count(*) INTO live_bad
    FROM model_versions v JOIN seasons s ON s.id = v.season_id
   WHERE s.closed_at IS NULL
     AND model_ratings(v.id, deploy_sigma)::jsonb IS DISTINCT FROM pg_temp.legacy_model_ratings(v.id, deploy_sigma)::jsonb;
  IF live_bad <> 0 THEN
    RAISE EXCEPTION 'verify: % live version(s) whose ratings read differently', live_bad;
  END IF;
  -- A closed season's version: every key the old answer had is unchanged, except a class key that a
  -- frozen class row now backs.
  SELECT count(*) INTO closed_bad
    FROM model_versions v JOIN seasons s ON s.id = v.season_id
    CROSS JOIN LATERAL jsonb_each(pg_temp.legacy_model_ratings(v.id, deploy_sigma)::jsonb) o (k, val)
   WHERE s.closed_at IS NOT NULL
     AND (model_ratings(v.id, deploy_sigma)::jsonb -> o.k) IS DISTINCT FROM o.val
     AND NOT (o.k = v.weight_class::text
              AND EXISTS (SELECT 1 FROM ratings c WHERE c.version_id = v.id AND c.ladder = v.weight_class));
  IF closed_bad <> 0 THEN
    RAISE EXCEPTION 'verify: % closed-season rating key(s) changed that no frozen class row explains', closed_bad;
  END IF;
  SELECT count(*) INTO corrected
    FROM model_versions v JOIN seasons s ON s.id = v.season_id
   WHERE s.closed_at IS NOT NULL
     AND model_ratings(v.id, deploy_sigma)::jsonb IS DISTINCT FROM pg_temp.legacy_model_ratings(v.id, deploy_sigma)::jsonb;
  RAISE NOTICE 'verify: live versions'' ratings unchanged; % closed-season version(s) now show their frozen class row', corrected;
END
$versions$;

-- 6. The season document: a closed season's is its record's summary, which must read as the season
--    read before; a live one's is computed as before.
DO $seasons$
DECLARE bad text;
BEGIN
  SELECT string_agg(s.slug, ', ') INTO bad FROM seasons s
   WHERE season_json(s)::jsonb IS DISTINCT FROM pg_temp.legacy_season_json(s.id)::jsonb;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'verify: the season document of % reads differently', bad;
  END IF;
  RAISE NOTICE 'verify: every season document reads as before';
END
$seasons$;

DO $seal$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_trigger
   WHERE NOT tgisinternal AND tgname LIKE '%\_sealed' AND tgrelid::regclass::text NOT LIKE 'legacy.%';
  IF n <> 10 THEN
    RAISE EXCEPTION 'verify: % seal trigger(s) installed, expected 10', n;
  END IF;
  RAISE NOTICE 'verify: every check passed';
END
$seal$;
