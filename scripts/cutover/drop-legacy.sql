-- DROP THE SCHEMAS A CUTOVER KEPT FOR ITS ROLLBACK, behind a gate. Run by drop-legacy.sh, which
-- mounts this directory at /d. Variables: on_digest (the schema `public` must be on), commit (true
-- to keep the drops, false to roll each one back), fingerprint ('' for none, or the closed seasons'
-- fingerprint recorded earlier, whole or a prefix).
--
-- The leftovers are fixed names: `legacy` (the schema a cutover replaced), `legacy_072` (the one
-- before it, from a chained window) and the `*_rolled_back` copies a rollback leaves. Each is
-- dropped in its own transaction, guarded by a count of every object OUTSIDE the leftovers taken
-- before the first drop: DROP SCHEMA ... CASCADE takes whatever depends on what it drops, so a
-- drop that moved that count is rolled back and refused. A dry run performs every drop and rolls
-- it back -- a dependent, a missing privilege or a lock it cannot get fails the dry run, not the
-- real one.

\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset footer off

-- A refusal is an ERROR, so psql exits non-zero under ON_ERROR_STOP and the caller stops. A \quit
-- with an exit code does not do that: psql ignores the code, warns, and exits 0.
CREATE FUNCTION pg_temp.refuse(why text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'REFUSED: %', why;
END
$f$;

-- 1. Only on the schema this release serves. After a rollback, `public` is the OLD schema and the
--    copy worth keeping is exactly one this would drop.
SELECT coalesce((SELECT digest FROM public.soma_schema) = :'on_digest', false) AS on_expected_schema \gset
\if :on_expected_schema
\else
  SELECT pg_temp.refuse('public is not on the schema this release serves (expected ' || :'on_digest'
                        || ') -- after a rollback, the copy to keep is one this would drop');
\endif

CREATE TEMP TABLE leftover AS
SELECT n.oid AS nsp, n.nspname::text AS name,
       (SELECT count(*) FROM pg_class c WHERE c.relnamespace = n.oid) AS relations,
       (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = n.oid) AS functions,
       coalesce((SELECT sum(pg_total_relation_size(c.oid)) FROM pg_class c
                  WHERE c.relnamespace = n.oid AND c.relkind IN ('r', 'm', 'p')), 0) AS bytes
  FROM pg_namespace n
 WHERE n.nspname IN ('legacy', 'legacy_072', 'v091_rolled_back', 'v092_rolled_back', 'v2_rolled_back');

\echo '==> schemas kept for a rollback:'
SELECT name AS schema, relations, functions, pg_size_pretty(bytes) AS size FROM leftover ORDER BY name;
SELECT count(*) > 0 AS anything FROM leftover \gset
\if :anything
\else
  \echo '==> none here: nothing to drop in this database'
  \quit
\endif

-- 2. THE GATE. Every closed season must read from `public` exactly as it does from `legacy`, the
--    copy the cutover took; with no `legacy` left, FINGERPRINT is the only reference there is.
\set sch public
\set into fp_public
\i /d/fingerprint.sql
SELECT to_regnamespace('legacy') IS NOT NULL AS have_legacy \gset
\if :have_legacy
  \set sch legacy
  \set into fp_legacy
  \i /d/fingerprint.sql
\else
  CREATE TEMP TABLE fp_legacy AS SELECT * FROM fp_public WHERE false;
\endif

\echo '==> closed seasons, from public (and whether legacy reads the same):'
SELECT p.slug, left(p.ratings_md5, 8) AS ratings, left(p.events_md5, 8) AS events, left(p.podium_md5, 8) AS podium,
       left(p.seats_md5, 8) AS seats, left(p.versions_md5, 8) AS versions, p.matches_played,
       CASE WHEN NOT EXISTS (SELECT 1 FROM fp_legacy l WHERE l.slug = p.slug) THEN 'not in legacy'
            WHEN EXISTS (SELECT p.* INTERSECT SELECT l.* FROM fp_legacy l) THEN 'same'
            ELSE 'MOVED' END AS against_legacy
  FROM fp_public p ORDER BY p.closed_epoch, p.slug;

SELECT coalesce(md5(string_agg(concat_ws('|', slug, coalesce(ratings_md5, '-'), coalesce(events_md5, '-'),
                                         coalesce(podium_md5, '-'), coalesce(seats_md5, '-'), coalesce(versions_md5, '-'),
                                         matches_played, closed_epoch, engine_digest),
                               E'\n' ORDER BY closed_epoch, slug)), 'none') AS fp
  FROM fp_public \gset
\echo '==> fingerprint of the closed seasons:' :fp

SELECT (SELECT count(*) FROM (TABLE fp_legacy EXCEPT TABLE fp_public) x) AS moved,
       (SELECT count(*) FROM fp_legacy) AS in_legacy \gset
SELECT :'have_legacy'::bool AND :moved = 0 AS proven_by_legacy,
       :'fingerprint' <> '' AND :'fp' LIKE :'fingerprint' || '%' AS proven_by_fingerprint,
       :'fingerprint' <> '' AND NOT (:'fp' LIKE :'fingerprint' || '%') AS fingerprint_wrong \gset
\if :fingerprint_wrong
  SELECT pg_temp.refuse('the closed seasons'' fingerprint is ' || :'fp' || ', not the ' || :'fingerprint' || ' recorded');
\endif
\if :have_legacy
  \if :proven_by_legacy
    \echo '    closed seasons in legacy that read the same from public:' :in_legacy
  \else
    SELECT pg_temp.refuse(:moved || ' closed season(s) read differently from public than from legacy -- a closed season has moved');
  \endif
\elif :proven_by_fingerprint
  \echo '    no legacy schema left to compare against; the fingerprint matches the one given'
\else
  SELECT pg_temp.refuse('no legacy schema to compare the closed seasons against -- set FINGERPRINT to the one recorded');
\endif

-- What the record of a closed season also rests on: none of its matches left to count (count's fold
-- has no season filter, so a `finished` one would move its ratings), a podium for every one that
-- played, and no rating event added to one since yesterday.
SELECT (SELECT count(*) FROM matches m JOIN seasons s ON s.id = m.season_id
         WHERE s.closed_at IS NOT NULL AND m.status::text NOT IN ('rated', 'cancelled', 'failed')) AS unfinished,
       (SELECT count(*) FROM seasons s
         WHERE s.closed_at IS NOT NULL AND s.matches_played > 0
           AND NOT EXISTS (SELECT 1 FROM season_podium p WHERE p.season_id = s.id)) AS no_podium,
       (SELECT count(*) FROM rating_events e JOIN model_versions v ON v.id = e.version_id JOIN seasons s ON s.id = v.season_id
         WHERE s.closed_at IS NOT NULL AND e.created_at > now() - interval '1 day') AS fresh_events \gset
SELECT :unfinished = 0 AND :no_podium = 0 AND :fresh_events = 0 AS records_hold \gset
\if :records_hold
  \echo '    closed seasons: 0 unfinished matches, every one that played has a podium, 0 rating events since yesterday'
\else
  SELECT pg_temp.refuse(format('closed seasons have %s unfinished match(es), %s missing podium(s), %s rating event(s) since yesterday',
                               :unfinished, :no_podium, :fresh_events));
\endif

-- Nothing outside the leftovers may depend on anything inside them. Every dependency on an object
-- in one -- or on the schema itself -- is classified by pg_identify_object, whatever its catalog. A
-- table's own parts (a default, a trigger, a rule, a policy, a constraint) have no schema of their
-- own there and take their table's; a dependent with none at all (a cast, a publication) counts as
-- outside. TOAST is theirs.
WITH refs AS MATERIALIZED (
  SELECT d.classid, d.objid, d.objsubid FROM pg_depend d
   WHERE (d.refclassid = 'pg_namespace'::regclass AND d.refobjid IN (SELECT nsp FROM leftover))
      OR (pg_identify_object(d.refclassid, d.refobjid, 0)).schema IN (SELECT name FROM leftover)),
deps AS (
  SELECT dep.type, dep.identity,
         coalesce(dep.schema,
                  (SELECT c.relnamespace::regnamespace::text FROM pg_class c WHERE c.oid = CASE refs.classid
                     WHEN 'pg_attrdef'::regclass    THEN (SELECT adrelid  FROM pg_attrdef    WHERE oid = refs.objid)
                     WHEN 'pg_trigger'::regclass    THEN (SELECT tgrelid  FROM pg_trigger    WHERE oid = refs.objid)
                     WHEN 'pg_rewrite'::regclass    THEN (SELECT ev_class FROM pg_rewrite    WHERE oid = refs.objid)
                     WHEN 'pg_policy'::regclass     THEN (SELECT polrelid FROM pg_policy     WHERE oid = refs.objid)
                     WHEN 'pg_constraint'::regclass THEN (SELECT conrelid FROM pg_constraint WHERE oid = refs.objid) END),
                  CASE WHEN refs.classid = 'pg_constraint'::regclass
                       THEN (SELECT connamespace::regnamespace::text FROM pg_constraint WHERE oid = refs.objid) END) AS schema
    FROM refs CROSS JOIN LATERAL pg_identify_object(refs.classid, refs.objid, refs.objsubid) dep)
SELECT count(*) AS dependents,
       coalesce(string_agg(DISTINCT type || ' ' || identity, '; '), '') AS which
  FROM deps
 WHERE schema IS DISTINCT FROM 'pg_toast'
   AND (schema IS NULL OR schema NOT IN (SELECT name FROM leftover)) \gset
SELECT :dependents > 0 AS has_dependents \gset
\if :has_dependents
  SELECT pg_temp.refuse(:dependents || ' object(s) outside the schemas to drop depend on something inside them: '
                        || left(:'which', 400));
\endif
\echo '    nothing outside them depends on them'

-- 3. THE DROPS. The guard: every object in every schema that stays -- each column too, since a
--    CASCADE can take one column of a table whose type it drops -- and the database-wide casts and
--    publication tables, counted now and again inside each drop's transaction.
CREATE TEMP VIEW kept_objects AS
SELECT n.nspname::text AS nspname, x.cat, count(*) AS n
  FROM (SELECT 'relation' AS cat, relnamespace AS nsp FROM pg_class
        UNION ALL SELECT 'column', c.relnamespace FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                   WHERE a.attnum > 0 AND NOT a.attisdropped
        UNION ALL SELECT 'function', pronamespace FROM pg_proc
        UNION ALL SELECT 'type', typnamespace FROM pg_type
        UNION ALL SELECT 'constraint', connamespace FROM pg_constraint
        UNION ALL SELECT 'default', c.relnamespace FROM pg_attrdef a JOIN pg_class c ON c.oid = a.adrelid
        UNION ALL SELECT 'trigger', c.relnamespace FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        UNION ALL SELECT 'rule', c.relnamespace FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class
        UNION ALL SELECT 'policy', c.relnamespace FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid) x
  JOIN pg_namespace n ON n.oid = x.nsp
 WHERE n.nspname NOT IN (SELECT name FROM leftover)
   AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
 GROUP BY 1, 2
UNION ALL SELECT '(database)', 'cast', count(*) FROM pg_cast
UNION ALL SELECT '(database)', 'publication table', count(*) FROM pg_publication_rel;
CREATE TEMP TABLE kept_before AS SELECT * FROM kept_objects;

SELECT format('SELECT %L AS step', '==> drop schema ' || name || ': ' || relations || ' relations, '
              || functions || ' functions, ' || pg_size_pretty(bytes)),
       'BEGIN',
       'SET LOCAL lock_timeout = ''10s''',
       format('DROP SCHEMA %I CASCADE', name),
       $q$DO $g$
BEGIN
  IF EXISTS (TABLE kept_before EXCEPT TABLE kept_objects) OR EXISTS (TABLE kept_objects EXCEPT TABLE kept_before) THEN
    RAISE EXCEPTION 'REFUSED: dropping it took something outside it -- rolled back';
  END IF;
END
$g$$q$,
       CASE WHEN :'commit' = 'true' THEN 'COMMIT' ELSE 'ROLLBACK' END
  FROM leftover ORDER BY name
\gexec
\if :commit
  \echo '==> COMMITTED: the schemas above are gone'
\else
  \echo '==> DRY RUN: every drop ran and was rolled back; nothing changed'
\endif
