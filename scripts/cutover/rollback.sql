-- UNDO A CUTOVER: the old schema back as `public`, the new one kept aside as `v2_rolled_back`.
-- Stop every soma node and runner first, then run the old image again (its bootstrap finds the old
-- digest and says the schema is current). Anything written on the new schema in between stays in
-- `v2_rolled_back` and does not come back with the old one.
--
--   psql "$SOMA_DB_URL" -v ON_ERROR_STOP=1 -f scripts/cutover/rollback.sql

\set ON_ERROR_STOP on
BEGIN;
SELECT to_regnamespace('legacy') IS NOT NULL AND to_regnamespace('v2_rolled_back') IS NULL AS can_roll_back \gset
\if :can_roll_back
\else
  \echo 'REFUSED: there is no `legacy` schema to go back to, or a `v2_rolled_back` is already here'
  \quit 3
\endif
ALTER SCHEMA public RENAME TO v2_rolled_back;
ALTER SCHEMA legacy RENAME TO public;
COMMIT;
\echo '==> rolled back: the old schema is public again'
