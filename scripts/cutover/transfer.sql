-- THE DATA, FROM THE OLD SCHEMA INTO THE NEW ONE. Run by cutover.sql inside its one transaction,
-- after the new migrations have built schema `v2` beside the old `public` and before the two swap
-- names. Nothing here names a table: it walks the catalogue, so a table or column the two schemas
-- share is copied whatever it is, and anything that would be LOST is refused by name instead.
--
--   * Every old table must have a new home, and every old column. Anything missing is an error, not
--     a silent drop. (A release that moves a column says so here, as a hand mapping after the copy.)
--   * Tables are copied in any order, with the new schema's foreign keys dropped for the copy and
--     added back after it, which checks every row against them (the schema has key cycles, so no
--     order would do). A key on a column the old schema did not have starts at its default.
--   * A column of one of Soma's own types (an enum, an array of one) is cast through text, since
--     `public.ladder` and `v2.ladder` are different types with the same labels.
--   * Generated columns are left to compute (`model_versions.artifact_key`, `ratings.conservative`),
--     and verify.sql checks each still equals what the old schema stored.
--   * The migrations' own seed rows (`clocks`) are thrown away first, so the old rows -- with their
--     fences and epochs -- come across unchanged.
--   * Each table's row count is checked on the spot.

DO $transfer$
DECLARE
  pending  text[];
  t        text;
  cols     text;
  sel      text;
  n_old    bigint;
  n_new    bigint;
  missing  text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO missing
    FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
     AND c.relname <> 'soma_schema'
     AND to_regclass(format('v2.%I', c.relname)) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'old tables with no home in the new schema (their rows would be lost): %', missing;
  END IF;

  SELECT string_agg(c.relname || '.' || o.attname, ', ' ORDER BY c.relname, o.attname) INTO missing
    FROM pg_class c
    JOIN pg_attribute o ON o.attrelid = c.oid AND o.attnum > 0 AND NOT o.attisdropped
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
     AND c.relname <> 'soma_schema'
     AND NOT EXISTS (SELECT 1 FROM pg_attribute n
                      WHERE n.attrelid = to_regclass(format('v2.%I', c.relname))
                        AND n.attname = o.attname AND NOT n.attisdropped);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'old columns with no home in the new schema (their values would be lost): %', missing;
  END IF;

  SELECT array_agg(c.relname::text ORDER BY c.relname) INTO pending
    FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
     AND c.relname <> 'soma_schema';

  -- The seed rows, and nothing else. The TRUNCATE cascades into the new-only tables that point at
  -- these, so first make sure the migrations seeded none of those: a default list there would
  -- otherwise vanish without a word.
  FOR t IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'v2'::regnamespace AND c.relkind IN ('r', 'p')
              AND c.relname::text <> ALL (pending)
  LOOP
    EXECUTE format('SELECT count(*) FROM v2.%I', t) INTO n_new;
    IF n_new > 0 THEN
      RAISE EXCEPTION 'the new migrations seed % row(s) into %, which the copy would truncate', n_new, t;
    END IF;
  END LOOP;
  SET LOCAL client_min_messages = warning;
  EXECUTE (SELECT 'TRUNCATE ' || string_agg(format('v2.%I', x), ', ') || ' CASCADE' FROM unnest(pending) x);
  SET LOCAL client_min_messages = notice;

  -- THE COPY IGNORES ORDER. The schema has foreign-key cycles (a board's latest match, a match's
  -- board), so no table order satisfies every key. Each new table's keys are dropped, every row is
  -- copied, and each key is added back exactly as the migration declared it -- which re-checks every
  -- row, so a dangling reference still fails the cutover, just after the copy instead of during it.
  -- The new tables' own triggers are off for the copy: a row arriving is not an event (a comment's
  -- insert would count its thread twice, the seal would refuse a closed season's ratings). The
  -- definitions are read with an empty search_path so each names its schema.
  PERFORM set_config('search_path', 'pg_catalog', true);
  CREATE TEMP TABLE transfer_fks ON COMMIT DROP AS
    SELECT k.conrelid::regclass::text AS tbl, k.conname, pg_get_constraintdef(k.oid) AS def
      FROM pg_constraint k
     WHERE k.contype = 'f' AND k.connamespace = 'v2'::regnamespace;
  PERFORM set_config('search_path', 'v2', true);
  FOR t IN SELECT format('ALTER TABLE %s DROP CONSTRAINT %I', f.tbl, f.conname) FROM transfer_fks f LOOP
    EXECUTE t;
  END LOOP;
  FOREACH t IN ARRAY pending LOOP
    EXECUTE format('ALTER TABLE v2.%I DISABLE TRIGGER USER', t);
  END LOOP;

  FOREACH t IN ARRAY pending LOOP
    SELECT string_agg(quote_ident(na.attname), ', ' ORDER BY na.attnum),
           string_agg(CASE WHEN nt.typnamespace = 'v2'::regnamespace
                             OR et.typnamespace = 'v2'::regnamespace
                           THEN format('%I::text::%s', na.attname, format_type(na.atttypid, na.atttypmod))
                           ELSE quote_ident(na.attname) END, ', ' ORDER BY na.attnum)
      INTO cols, sel
      FROM pg_attribute na
      JOIN pg_type nt ON nt.oid = na.atttypid
      LEFT JOIN pg_type et ON et.oid = nt.typelem AND nt.typelem <> 0
     WHERE na.attrelid = format('v2.%I', t)::regclass
       AND na.attnum > 0 AND NOT na.attisdropped AND na.attgenerated = ''
       AND EXISTS (SELECT 1 FROM pg_attribute oa
                    WHERE oa.attrelid = format('public.%I', t)::regclass
                      AND oa.attname = na.attname AND NOT oa.attisdropped);

    EXECUTE format('INSERT INTO v2.%I (%s) SELECT %s FROM public.%I', t, cols, sel, t);
    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n_old;
    EXECUTE format('SELECT count(*) FROM v2.%I', t) INTO n_new;
    IF n_old <> n_new THEN
      RAISE EXCEPTION 'copying %: % rows in the old table, % in the new', t, n_old, n_new;
    END IF;
    RAISE NOTICE 'copied %: % rows', rpad(t, 24), n_new;
  END LOOP;

  FOREACH t IN ARRAY pending LOOP
    EXECUTE format('ALTER TABLE v2.%I ENABLE TRIGGER USER', t);
  END LOOP;
  FOR t IN SELECT format('ALTER TABLE %s ADD CONSTRAINT %I %s', f.tbl, f.conname, f.def) FROM transfer_fks f LOOP
    EXECUTE t;
  END LOOP;
  RAISE NOTICE 'every foreign key holds over the copied rows (% keys)', (SELECT count(*) FROM transfer_fks);

  -- Sequences, where the two schemas share one (none today; this keeps a future one honest).
  FOR t IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
              AND to_regclass(format('v2.%I', c.relname)) IS NOT NULL
  LOOP
    EXECUTE format('SELECT setval(%L, last_value, is_called) FROM public.%I', 'v2.' || quote_ident(t), t);
  END LOOP;
END
$transfer$;
