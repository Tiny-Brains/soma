-- WHAT THE CUTOVER MUST HAVE KEPT. Run by cutover.sql inside its one transaction, after the swap
-- (`legacy` is the old schema, `public` the new one) and the backfill. Every check RAISES, so a
-- failure rolls the whole cutover back and the site comes up on the schema it went down on.
-- It prints counts and ids only -- never a handle, a name or a session.

DO $verify$
DECLARE
  t       text;
  n_old   bigint;
  n_new   bigint;
  bad     bigint;
  report  text := '';
BEGIN
  -- 1. Every row of every old table is still here, but the per-class ladder rows of a season still
  --    live, which the backfill drops on purpose (one rated ladder: a class is a view of Open). A
  --    closed season keeps its class rows: they are its class tables as they stood.
  FOR t IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'legacy'::regnamespace AND c.relkind IN ('r', 'p')
              AND c.relname <> 'soma_schema' ORDER BY c.relname
  LOOP
    IF t IN ('ratings', 'rating_events') THEN
      EXECUTE format('SELECT count(*) FROM legacy.%I x WHERE x.ladder::text = ''open''
                         OR EXISTS (SELECT 1 FROM legacy.model_versions v JOIN legacy.seasons s ON s.id = v.season_id
                                     WHERE v.id = x.version_id AND s.closed_at IS NOT NULL)', t) INTO n_old;
    ELSE
      EXECUTE format('SELECT count(*) FROM legacy.%I', t) INTO n_old;
    END IF;
    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n_new;
    IF n_old <> n_new THEN
      RAISE EXCEPTION 'verify: % has % rows, expected %', t, n_new, n_old;
    END IF;
    report := report || format(E'\n  %s %s', rpad(t, 24), n_new);
  END LOOP;
  RAISE NOTICE 'rows kept:%', report;

  -- 2. Every human can sign in as themselves: one github identity each, on their old GitHub id.
  SELECT count(*) INTO bad
    FROM legacy.users o
   WHERE o.github_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.identities i
                      WHERE i.user_id = o.id AND i.provider = 'github' AND i.subject = o.github_id::text);
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % account(s) lost their GitHub identity', bad; END IF;
  SELECT count(*) INTO bad FROM public.users u
   WHERE (u.role = 'baseline') = EXISTS (SELECT 1 FROM public.identities i WHERE i.user_id = u.id);
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % account(s) have an identity when a baseline, or none when a human', bad; END IF;

  -- 3. Nobody is renamed, re-roled or signed out.
  SELECT count(*) INTO bad FROM legacy.users o JOIN public.users n USING (id)
   WHERE n.handle <> o.handle OR n.role::text <> o.role::text
      OR n.display_name IS DISTINCT FROM o.display_name;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % account(s) changed handle, role or display name', bad; END IF;
  SELECT count(*) INTO n_old FROM legacy.live_sessions;
  SELECT count(*) INTO n_new FROM public.live_sessions;
  IF n_old <> n_new THEN RAISE EXCEPTION 'verify: % live sessions before, % after', n_old, n_new; END IF;

  -- 4. Every runner that could claim still can.
  SELECT count(*) INTO n_old FROM legacy.live_runner_keys;
  SELECT count(*) INTO n_new FROM public.live_runner_keys;
  IF n_old <> n_new THEN RAISE EXCEPTION 'verify: % live runner keys before, % after', n_old, n_new; END IF;
  SELECT count(*) INTO n_old FROM legacy.live_runners;
  SELECT count(*) INTO n_new FROM public.live_runners;
  IF n_old <> n_new THEN RAISE EXCEPTION 'verify: % live runners before, % after', n_old, n_new; END IF;

  -- 5. Every stored object is found where it was: the generated keys agree.
  SELECT count(*) INTO bad FROM legacy.model_versions o JOIN public.model_versions n USING (id)
   WHERE n.artifact_key IS DISTINCT FROM o.artifact_key;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % version(s) moved artifact key', bad; END IF;
  SELECT count(*) INTO bad FROM legacy.ratings o
    JOIN public.ratings n ON n.version_id = o.version_id AND n.ladder::text = o.ladder::text
   WHERE n.conservative IS DISTINCT FROM o.conservative OR n.matches_played <> o.matches_played;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % rating(s) changed', bad; END IF;

  -- 6. The season a visitor lands on is the one they landed on yesterday: the live one, else the
  --    newest. current_season() is what every public read resolves "no season named" through.
  SELECT count(*) INTO bad
    FROM public.games g
    JOIN LATERAL (SELECT s.id FROM legacy.seasons s WHERE s.game_id = g.id
                   ORDER BY (s.closed_at IS NULL) DESC, s.number DESC LIMIT 1) o ON true
    LEFT JOIN LATERAL current_season(g.id) n ON true
   WHERE n.id IS DISTINCT FROM o.id;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % game(s) would open on a different season', bad; END IF;

  -- 7. The rating chain (ratings.matches_played is the rating_events seq): a break fails every fold.
  SELECT count(*) INTO bad FROM (
    SELECT 1 FROM public.ratings r JOIN public.rating_events e USING (version_id, ladder)
     GROUP BY r.version_id, r.ladder, r.matches_played HAVING r.matches_played < max(e.seq)) x;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % rating(s) behind their last event', bad; END IF;

  -- 8. What a clock resumes from: fences and epochs as they were.
  SELECT count(*) INTO bad FROM legacy.clocks o FULL JOIN public.clocks n USING (key)
   WHERE row(n.*)::text IS DISTINCT FROM row(o.*)::text;
  IF bad > 0 THEN RAISE EXCEPTION 'verify: % clock row(s) differ', bad; END IF;

  RAISE NOTICE 'verify: every check passed';
END
$verify$;
