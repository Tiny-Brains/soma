-- THE CUTOVER, AS ONE TRANSACTION. Run by cutover.sh, which mounts this directory at /cut with the
-- new image's migrations (their own BEGIN/COMMIT stripped) under /cut/migrations and a generated
-- /cut/apply.sql that \i's them in order. Variables: from_digest (the schema this database must be
-- on), to_digest (the one the new migrations hash to), commit (true to keep it, false to roll back).
--
-- Postgres DDL is transactional, so the new schema is built BESIDE the old one, filled, derived,
-- checked and swapped in one go: either every step lands or the database is exactly as it was. The
-- old schema is not dropped -- it is renamed `legacy`, and `rollback.sql` swaps it back.

\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;
SET LOCAL lock_timeout = '10s';

-- Only from the schema this was written for, and only once.
SELECT (SELECT digest FROM public.soma_schema) = :'from_digest' AS on_expected_schema \gset
\if :on_expected_schema
\else
  \echo 'REFUSED: this database is not on the schema the cutover starts from (expected ' :'from_digest' ')'
  \quit 3
\endif
SELECT to_regnamespace('legacy') IS NULL AND to_regnamespace('v2') IS NULL AS fresh \gset
\if :fresh
\else
  \echo 'REFUSED: a `legacy` or `v2` schema is already here -- a cutover has run (rollback.sql undoes one)'
  \quit 3
\endif

-- The new schema, with the old public schema's grants: USAGE for everyone (so `runner_gate` and
-- the managed provider's own roles resolve names in it) and whatever else was granted on it.
CREATE SCHEMA v2;
DO $acl$
DECLARE a record;
BEGIN
  FOR a IN SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END AS who,
                  x.privilege_type AS what
             FROM pg_namespace n
            CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) x
             LEFT JOIN pg_roles r ON r.oid = x.grantee
            WHERE n.nspname = 'public' AND x.grantee <> n.nspowner
  LOOP
    EXECUTE format('GRANT %s ON SCHEMA v2 TO %s', a.what, a.who);
  END LOOP;
  -- A default ACL on public grants PUBLIC USAGE; make sure the new schema has it either way.
  EXECUTE 'GRANT USAGE ON SCHEMA v2 TO PUBLIC';
END
$acl$;

\echo '==> building the new schema beside the old one'
SET LOCAL search_path = v2;
\i /cut/apply.sql

\echo '==> copying the data'
\i /cut/transfer.sql

\echo '==> swapping: public -> legacy, v2 -> public'
ALTER SCHEMA public RENAME TO legacy;
ALTER SCHEMA v2 RENAME TO public;
-- The owner a fresh database's public schema has, where the role may hand it over; otherwise it
-- stays the migrating role's, which owns every object in it anyway and which nothing checks.
DO $own$
BEGIN
  ALTER SCHEMA public OWNER TO pg_database_owner;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'public stays owned by %: this role may not hand it to pg_database_owner', current_user;
END
$own$;
SET LOCAL search_path = public;

-- The digest bootstrap checks, in the table bootstrap keeps it in (see entrypoint.sh).
CREATE TABLE public.soma_schema (
  singleton  boolean     PRIMARY KEY DEFAULT true CHECK (singleton),
  digest     text        NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.soma_schema (singleton, digest) VALUES (true, :'to_digest');

\echo '==> deriving what the new schema adds'
\i /cut/backfill.sql

\echo '==> verifying'
\i /cut/verify.sql

\if :commit
  COMMIT;
  \echo '==> COMMITTED. The old schema is `legacy`; rollback.sql swaps it back.'
\else
  ROLLBACK;
  \echo '==> DRY RUN: everything above passed, and it was rolled back. Nothing changed.'
\endif
