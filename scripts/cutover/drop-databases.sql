-- DROP THE DATABASES A CUTOVER KEPT FOR ITS ROLLBACK: `orion_state_pre_cutover`, the copy of Orion's
-- state retire.sh's rollback restores, and `orion_state_v2`, a retried window's. Run by
-- drop-legacy.sh against the cluster's `postgres` database, after drop-legacy.sql has passed its
-- gate. Variables: commit (true to drop). A database cannot be dropped inside a transaction, so
-- there is no rolled-back rehearsal of this part: the dry run lists what it would drop.

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

SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'orion_state') AS live_state \gset
\if :live_state
\else
  SELECT pg_temp.refuse('no orion_state database here -- this is not the cluster the cutover ran on');
\endif

CREATE TEMP TABLE gone AS
SELECT d.datname::text AS name, pg_get_userbyid(d.datdba) AS owner, pg_database_size(d.datname) AS bytes,
       (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname) AS sessions
  FROM pg_database d
 WHERE d.datname IN ('orion_state_pre_cutover', 'orion_state_v2') AND d.datname <> current_database();

\echo '==> databases kept for a rollback:'
SELECT name AS database, owner, pg_size_pretty(bytes) AS size, sessions FROM gone ORDER BY name;
SELECT count(*) > 0 AS anything FROM gone \gset
\if :anything
\else
  \echo '==> none here'
  \quit
\endif

\if :commit
  SELECT format('DROP DATABASE IF EXISTS %I', name) FROM gone ORDER BY name
  \gexec
  \echo '==> COMMITTED: the databases above are gone'
\else
  \echo '==> DRY RUN: listed only (DROP DATABASE cannot run inside a transaction to be rolled back)'
\endif
