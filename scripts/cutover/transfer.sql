-- THE DATA, FROM THE OLD SCHEMA INTO THE NEW ONE. Run by cutover.sql inside its one transaction,
-- after the new migrations have built schema `v2` beside the old `public` and before the two swap
-- names. Nothing here names a table: it walks the catalogue, so a table or column the two schemas
-- share is copied whatever it is, and anything that would be LOST is refused by name instead.
--
--   * Every old table must have a new home, and every old column but the ones mapped by hand below
--     (`users.github_id`, which becomes an `identities` row). Anything else missing is an error,
--     not a silent drop.
--   * Tables are copied parents first: a table goes once every table its copied foreign keys point
--     at has gone. A foreign key on a column the old schema did not have is ignored -- the column
--     starts at its default (null for every such key), so it points nowhere yet.
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
  done     text[] := '{}';
  t        text;
  ready    boolean;
  progress boolean;
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
     AND (c.relname, o.attname::text) NOT IN (('users', 'github_id'))
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

  WHILE cardinality(pending) > 0 LOOP
    progress := false;
    FOREACH t IN ARRAY pending LOOP
      SELECT NOT EXISTS (
               SELECT 1
                 FROM pg_constraint k
                 JOIN pg_class p ON p.oid = k.confrelid
                WHERE k.conrelid = format('v2.%I', t)::regclass AND k.contype = 'f'
                  AND k.confrelid <> k.conrelid
                  AND p.relname::text <> ALL (done)
                  -- only a key whose every column is copied can point at anything yet
                  AND NOT EXISTS (
                        SELECT 1 FROM unnest(k.conkey) AS a (n)
                          JOIN pg_attribute na ON na.attrelid = k.conrelid AND na.attnum = a.n
                         WHERE NOT EXISTS (SELECT 1 FROM pg_attribute oa
                                            WHERE oa.attrelid = format('public.%I', t)::regclass
                                              AND oa.attname = na.attname AND NOT oa.attisdropped)))
        INTO ready;
      CONTINUE WHEN NOT ready;

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

      done := done || t;
      pending := array_remove(pending, t);
      progress := true;
    END LOOP;
    IF NOT progress THEN
      RAISE EXCEPTION 'cannot order these tables by their foreign keys (a cycle, or a key into a new table): %', pending;
    END IF;
  END LOOP;

  -- Sequences, where the two schemas share one (none today; this keeps a future one honest).
  FOR t IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
              AND to_regclass(format('v2.%I', c.relname)) IS NOT NULL
  LOOP
    EXECUTE format('SELECT setval(%L, last_value, is_called) FROM public.%I', 'v2.' || quote_ident(t), t);
  END LOOP;
END
$transfer$;

-- THE ONE HAND MAPPING. An account's GitHub id was `users.github_id`; it is now the account's
-- `github` identity, keyed (provider, subject) with the subject as text -- exactly what the sign-in
-- upsert looks up, so the next GitHub sign-in finds this row and the same user, never a new one.
-- `login` is the cache of the provider's current username, which the old handle WAS (the old
-- sign-in rewrote it on every visit), so a season's participant list resolves against it at once.
-- Baselines have no GitHub id and get no identity, which `users_baseline_handle_reserved` requires.
INSERT INTO v2.identities (user_id, provider, subject, login, created_at)
SELECT u.id, 'github', u.github_id::text, u.handle, u.created_at
  FROM public.users u
 WHERE u.github_id IS NOT NULL;
