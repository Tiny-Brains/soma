-- Every statement docs/schema.md §4-§7 and docs/rating-and-seasons.md §6 specify, PREPAREd so
-- Postgres parses and plans each, then EXECUTEd by scenario.sql and the race files. The statements
-- a season touches are taken from scripts/gen-clocks.py's text, so this harness walks what ships.
-- Parameter types are the casts those documents use.

-- THE EIGHT MATCH STATEMENTS ARE COPIED, VERBATIM, FROM soma/workflows/soma-runner-*.json,
-- which is where they ship from since the gate moved into this package. They were transcribed
-- by hand once and went stale without anyone noticing -- this file still carried the pre-R7
-- two-CTE wave claim, with resident-weights affinity, months after a one-row claim shipped --
-- so run.sh now asserts the copies are identical rather than trusting that they are.
--
-- THE THIRTEEN CLOCK STATEMENTS ARE COPIED VERBATIM TOO, from workflows/tb-*-run.json, and run.sh
-- compares them the same way: c_fence, c_batch_doc, c_priors, c_fold, c_pass, c_reject,
-- c_withdraw_pred, p_game, p_epoch, p_demand_doc, p_trials, p_insert and w_sweep. Regenerate them
-- from the workflows; never retype one. c_verdicts, c_decide and c_batch were earlier forms of
-- what count now reads as ONE document, c_batch_doc, and went when that was noticed.
--
-- HARNESS-ONLY, and nothing ships them: c_pass_reversed (the promotion with its two updates in
-- the opposite order, which the deferred one-active rule must still commit), a_chain (the audit
-- of the rating chain), d_demand (the demand view on its own, the shape devops' autoscaler.sql
-- reads) and the two s_* reads.

-- 4.1 reap -- the cron channel's only task, once a second in one place.
-- workflows/soma-runner-reap.json / reap
PREPARE k_reap AS
UPDATE matches SET status = CASE WHEN lapses + 1 >= 3 THEN 'failed' ELSE 'pending' END::match_status, lapses = lapses + 1, claim_token = NULL, lease_expires_at = NULL, fault_reason = CASE WHEN lapses + 1 >= 3 THEN 'LEASE_LAPSED' END, closed_at = CASE WHEN lapses + 1 >= 3 THEN now() END WHERE status IN ('claimed', 'running') AND lease_expires_at < now();

-- 4.2 claim. $1 engine digest, $2 token, $3 lease seconds, $4 seats the caller can play,
-- $5 the runner. The last is what the move off-site added: the live_runners EXISTS is the
-- demotion check and the in-flight count is the ceiling on a wedged machine.
-- workflows/soma-runner-claim.json / claim
PREPARE k_claim AS
WITH pick AS MATERIALIZED (SELECT m.id FROM matches m WHERE m.status = 'pending' AND m.engine_digest = ($1)::text AND m.seat_count <= ($4)::int AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($5)::uuid AND (SELECT count(*) FROM matches h WHERE h.played_by = ($5)::uuid AND h.status IN ('claimed', 'running')) < lr.max_in_flight) ORDER BY (m.trial_version_id IS NOT NULL) DESC, m.created_at, m.id LIMIT 1 FOR UPDATE SKIP LOCKED) UPDATE matches m SET status = 'claimed', claim_token = ($2)::uuid, lease_expires_at = now() + ($3)::int * interval '1 second', played_by = ($5)::uuid FROM pick WHERE m.id = pick.id;

-- 4.3 read the claimed row and its seats. $1 claim token, $2 model prefix.
-- workflows/soma-runner-claim.json / row
PREPARE k_row AS
SELECT json_build_object('id', m.id, 'seed', m.seed, 'preset', m.preset, 'seat_count', m.seat_count, 'trial_model_id', m.trial_version_id, 'strike_ceiling', m.strike_ceiling, 'seats', (SELECT json_agg(json_build_object('m', 0, 'seat', s.seat, 'version_id', s.version_id, 'model', ($2)::text || s.version_id::text, 'strike_ceiling', m.strike_ceiling, 'weights_hash', s.weights_hash, 'manifest_hash', s.manifest_hash) ORDER BY s.seat) FROM match_seats s WHERE s.match_id = m.id)) AS row, m.engine_digest AS engine_digest, m.lease_expires_at AS lease_expires_at, json_build_object('turn_ms', e.turn_ms, 'max_turns', e.max_turns, 'model_prefix', ($2)::text, 'engine_digest', m.engine_digest, 'replay_prefix', ($3)::text, 'renew_every_n_turns', GREATEST(1, LEAST(($4)::int, (($5)::int * 1000) / (3 * e.turn_ms))), 'lease_seconds', ($5)::int, 'refusal_ceiling', e.refusal_ceiling) AS contract FROM matches m JOIN seasons se ON se.id = m.season_id JOIN games g ON g.id = m.game_id CROSS JOIN LATERAL (SELECT coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'turn_ms')::int END, (g.manifest -> 'limits' ->> 'turn_ms')::int, ($6)::int) AS turn_ms, coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'max_turns')::int END, (g.manifest -> 'limits' ->> 'max_turns')::int, ($7)::int) AS max_turns, coalesce(CASE WHEN (se.rules -> 'execution' ->> 'enabled')::boolean THEN (se.rules -> 'execution' ->> 'refusal_ceiling')::int END, ($8)::int) AS refusal_ceiling) e WHERE m.claim_token = ($1)::uuid AND m.status = 'claimed';

-- 4.4 start. $1 token, $2 runner, $3 match.
-- workflows/soma-runner-start.json / start
PREPARE k_start AS
UPDATE matches SET status = 'running' WHERE id = ($3)::uuid AND claim_token = ($1)::uuid AND status = 'claimed' AND played_by = ($2)::uuid AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($2)::uuid);

-- 4.4 release -- not a fault and not a lapse. $1 token, $2 the refusal flag, $3 ceiling,
-- $4 runner, $5 match.
-- workflows/soma-runner-release.json / release
PREPARE k_release AS
UPDATE matches SET status = CASE WHEN refusals + 1 >= ($3)::int THEN 'failed' ELSE 'pending' END::match_status, refusals = refusals + 1, claim_token = NULL, lease_expires_at = NULL, fault_reason = CASE WHEN refusals + 1 >= ($3)::int THEN 'MODEL_UNAVAILABLE' END, closed_at = CASE WHEN refusals + 1 >= ($3)::int THEN now() END WHERE id = ($5)::uuid AND claim_token = ($1)::uuid AND status = 'claimed' AND ($2)::boolean AND played_by = ($4)::uuid AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($4)::uuid);

-- 4.5 renew, on the DATABASE's clock. $1 token, $2 lease seconds, $3 runner, $4 match.
-- workflows/soma-runner-renew.json / renew
PREPARE k_renew AS
UPDATE matches SET lease_expires_at = now() + ($2)::int * interval '1 second' WHERE id = ($4)::uuid AND claim_token = ($1)::uuid AND status = 'running' AND played_by = ($3)::uuid AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($3)::uuid);

-- 4.6 finish -- the row and all its seats, or neither. $1 token, $2 match, $3 the result,
-- $4 reason, $5 turns, $6 opened at, $7 engine digest, $8 orion version, $9 key, $10 runner.
-- workflows/soma-runner-finish.json / finish
PREPARE k_finish AS
WITH m AS (UPDATE matches SET status = 'finished', reason = ($4)::text, turns = ($5)::int, played_ms = GREATEST(0, (EXTRACT(EPOCH FROM (now() - ($6)::timestamptz)) * 1000)::int), engine_digest_played = ($7)::text, orion_version = ($8)::text, replay_key = ($9)::text, played_at = now(), lease_expires_at = NULL WHERE id = ($2)::uuid AND claim_token = ($1)::uuid AND status = 'running' AND played_by = ($10)::uuid AND EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = ($10)::uuid) AND (SELECT count(DISTINCT v.seat) FROM jsonb_to_recordset(($3)::jsonb) AS v (seat smallint) WHERE v.seat BETWEEN 0 AND seat_count - 1) = seat_count AND ($7)::text = engine_digest AND (SELECT min(v.rank) >= 1 AND max(v.rank) <= 2 * seat_count AND max(v.strikes) <= strike_ceiling FROM jsonb_to_recordset(($3)::jsonb) AS v (rank smallint, strikes smallint)) RETURNING id) UPDATE match_seats s SET rank = v.rank, score = v.score, strikes = v.strikes, infer_us_total = v.infer_us_total, infer_us_max = v.infer_us_max, infer_turns = v.infer_turns FROM m, jsonb_to_recordset(($3)::jsonb) AS v (seat smallint, rank smallint, score int, strikes smallint, infer_us_total bigint, infer_us_max int, infer_turns int) WHERE s.match_id = m.id AND s.seat = v.seat;

PREPARE c_fence AS
UPDATE clocks SET scheduled_for = ($1)::timestamptz, attempt = ($2)::int, updated_at = now() WHERE key = 'count' AND (scheduled_for, attempt) < (($1)::timestamptz, ($2)::int);

PREPARE c_priors AS
SELECT json_build_object( 'id', m.id, 'trial_model_id', m.trial_version_id, 'ladders', m.ladders, 'seat_count', m.seat_count, 'seats', (SELECT json_agg(json_build_object( 'seat', s.seat, 'model_id', s.version_id, 'rank', s.rank, 'strikes', s.strikes, 'ratings', (SELECT json_agg(json_build_object( 'ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma) ORDER BY r.ladder) FROM ratings r WHERE r.version_id = s.version_id AND r.ladder = ANY (m.ladders))) ORDER BY s.seat) FROM match_seats s WHERE s.match_id = m.id) ) AS row, coalesce((se.rules -> 'rating' ->> 'beta')::float8, ($2)::float8) AS beta, coalesce((se.rules -> 'rating' ->> 'tau')::float8, ($3)::float8) AS tau, coalesce((se.rules -> 'rating' ->> 'draw_probability')::float8, ($4)::float8) AS draw_probability FROM matches m JOIN seasons se ON se.id = m.season_id WHERE m.id = ($1)::uuid AND m.status = 'finished';

PREPARE c_fold AS
WITH fence AS ( SELECT key FROM clocks WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int FOR SHARE ), mark AS ( UPDATE matches m SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq') FROM fence WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id IS NULL AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders) RETURNING m.id ), post AS ( SELECT p.* FROM mark, jsonb_to_recordset(($4)::jsonb) AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8) ), applied AS ( UPDATE ratings r SET mu = post.mu, sigma = post.sigma, matches_played = r.matches_played + 1, updated_at = now() FROM post, ratings old WHERE r.version_id = post.model_id AND r.ladder = post.ladder::ladder AND old.version_id = r.version_id AND old.ladder = r.ladder RETURNING r.version_id, r.ladder, r.matches_played AS seq, post.seat, old.mu AS mu_before, old.sigma AS sigma_before, r.mu AS mu_after, r.sigma AS sigma_after ) INSERT INTO rating_events (version_id, ladder, seq, match_id, seat, mu_before, sigma_before, mu_after, sigma_after) SELECT a.version_id, a.ladder, a.seq, mark.id, a.seat, a.mu_before, a.sigma_before, a.mu_after, a.sigma_after FROM applied a, mark;

PREPARE c_pass AS
WITH fence AS ( SELECT key FROM clocks WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int FOR SHARE ), live AS ( SELECT s.id, coalesce((s.rules -> 'rating' ->> 'prior_mu')::float8, ($5)::float8) AS prior_mu, coalesce((s.rules -> 'rating' ->> 'prior_sigma')::float8, ($6)::float8) AS prior_sigma, coalesce((s.rules -> 'rating' ->> 'sigma_inflation')::float8, ($7)::float8) AS inflation FROM seasons s JOIN model_versions c ON c.season_id = s.id WHERE c.id = ($4)::uuid AND s.closed_at IS NULL ), mark AS ( UPDATE matches m SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq') FROM fence, live WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id = ($4)::uuid RETURNING m.id ), bump AS ( UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM mark WHERE c.key = 'roster' RETURNING c.epoch ), pred AS ( UPDATE model_versions p SET status = 'superseded' FROM bump, model_versions cand WHERE cand.id = ($4)::uuid AND p.model_id = cand.model_id AND p.season_id = cand.season_id AND p.status = 'active' RETURNING p.id ), cand AS ( UPDATE model_versions c SET status = 'active' FROM bump WHERE c.id = ($4)::uuid AND c.status = 'verified' AND (SELECT count(*) FROM pred) >= 0 RETURNING c.id, c.weight_class ), seeded AS ( INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma) SELECT cand.id, l.ladder, coalesce(prev.mu, live.prior_mu), coalesce(seed.sigma, live.prior_sigma), prev.mu, seed.sigma FROM cand CROSS JOIN live CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder) LEFT JOIN pred ON true LEFT JOIN ratings prev ON prev.version_id = pred.id AND prev.ladder = l.ladder CROSS JOIN LATERAL ( SELECT CASE WHEN prev.sigma IS NULL THEN NULL ELSE least(prev.sigma * live.inflation, live.prior_sigma) END AS sigma ) seed RETURNING version_id, ladder, mu, sigma ) INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after) SELECT version_id, ladder, 0, mu, sigma FROM seeded;


-- §9.1: the same promotion with the candidate activated BEFORE the predecessor is demoted.
-- Commits only because the one-active rule is deferred to commit.
PREPARE c_pass_reversed (timestamptz, int, uuid, uuid, float8, float8, float8) AS
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), live AS (
    -- 06 §6.4: the candidate's season must be live, and the guard sits on the mark because a
    -- data-modifying CTE runs whether or not the outer statement uses it. Never reached in
    -- practice -- a close rejects a waiting candidate in the same statement -- but never is a
    -- promise, and this is a predicate.
    SELECT s.id
      FROM seasons s JOIN model_versions c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), cand AS (
    UPDATE model_versions c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
 RETURNING c.id, c.weight_class, c.model_id, c.game_id, c.season_id
), pred AS (
    UPDATE model_versions p SET status = 'superseded'
      FROM bump, cand
     WHERE p.model_id = cand.model_id
       AND p.season_id = cand.season_id
       AND p.status = 'active' AND p.id <> cand.id
 RETURNING p.id
), seeded AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, ($5)::float8),
           coalesce(seed.sigma, ($6)::float8),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.version_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * ($7)::float8, ($6)::float8) END AS sigma
      ) seed
 RETURNING version_id, ladder, mu, sigma
)
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT version_id, ladder, 0, mu, sigma FROM seeded;

PREPARE c_reject AS
WITH fence AS ( SELECT key FROM clocks WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int FOR SHARE ), mark AS ( UPDATE matches m SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq') FROM fence WHERE m.id = ($3)::uuid AND m.status = 'finished' RETURNING m.id ), bump AS ( UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM fence WHERE c.key = 'roster' AND (SELECT count(*) FROM mark) >= 0 RETURNING c.epoch ) UPDATE model_versions v SET status = 'rejected', reject_reason = ($5)::text FROM bump WHERE v.id = ($4)::uuid AND v.status = 'verified';

PREPARE c_withdraw_pred AS
UPDATE matches m SET status = 'cancelled', withdrawn_reason = 'SUPERSEDED', successor_version_id = ($2)::uuid, closed_at = now() WHERE m.status = 'pending' AND EXISTS (SELECT 1 FROM match_seats s WHERE s.match_id = m.id AND s.version_id = ($1)::uuid);

PREPARE p_epoch AS
SELECT epoch FROM clocks WHERE key = 'roster';

PREPARE p_insert AS
WITH season AS ( SELECT s.id, s.game_id, s.engine_digest, s.rules FROM seasons s JOIN games g ON g.id = s.game_id AND g.slug = ($2)::text WHERE s.closed_at IS NULL ), seated AS MATERIALIZED ( SELECT seat.ord - 1 AS seat, v.id AS version_id, e.owner_id, v.weights_hash, v.manifest_hash, v.weight_class FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (version_id, ord) JOIN model_versions v ON v.id = seat.version_id JOIN models e ON e.id = v.model_id JOIN season ON season.id = v.season_id WHERE v.status = 'active' OR (v.status = 'verified' AND v.id = ($6)::uuid) ), m AS ( INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders, trial_version_id, pairing_id, strike_ceiling) SELECT season.game_id, season.id, season.engine_digest, ($3)::bigint, ($4)::text, cardinality(($5)::uuid[]), CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[] WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1 THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[] ELSE ARRAY['open']::ladder[] END, ($6)::uuid, ($7)::uuid, coalesce((season.rules -> 'pairing' ->> 'forfeit_strikes')::smallint, ($8)::smallint) FROM season JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence ON true WHERE (SELECT count(*) FROM seated) = cardinality(($5)::uuid[]) AND (($6)::uuid IS NOT NULL OR coalesce((season.rules -> 'pairing' ->> 'self_pairing')::bool, false) OR (SELECT count(DISTINCT owner_id) FROM seated) = cardinality(($5)::uuid[])) RETURNING id ) INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, paired_ratings) SELECT m.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash, (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma) ORDER BY r.ladder) FROM ratings r WHERE r.version_id = s.version_id) FROM m, seated s;

PREPARE w_sweep AS
UPDATE matches m SET status = 'cancelled', closed_at = now(), withdrawn_reason = CASE WHEN s.closed_at IS NOT NULL THEN 'SEASON_CLOSED' WHEN m.engine_digest <> s.engine_digest THEN 'ENGINE_RETIRED' ELSE (SELECT CASE v.status WHEN 'superseded' THEN 'SUPERSEDED' WHEN 'rejected' THEN 'REJECTED' ELSE 'SEAT_LEFT' END FROM match_seats st JOIN model_versions v ON v.id = st.version_id WHERE st.match_id = m.id AND NOT (v.status = 'active' OR (v.status = 'verified' AND v.id = m.trial_version_id)) ORDER BY st.seat LIMIT 1) END, successor_version_id = (SELECT succ.id FROM match_seats st JOIN model_versions gone ON gone.id = st.version_id AND gone.status = 'superseded' JOIN model_versions succ ON succ.model_id = gone.model_id AND succ.season_id = gone.season_id AND succ.status = 'active' WHERE st.match_id = m.id ORDER BY st.seat LIMIT 1) FROM seasons s WHERE s.id = m.season_id AND m.status = 'pending' AND (s.closed_at IS NOT NULL OR m.engine_digest <> s.engine_digest OR EXISTS (SELECT 1 FROM match_seats st JOIN model_versions v ON v.id = st.version_id WHERE st.match_id = m.id AND NOT (v.status = 'active' OR (v.status = 'verified' AND v.id = m.trial_version_id))));


-- Soma's history read under the two-table shape (§7.2): a plain join, no containment.
PREPARE s_history (uuid, int) AS
SELECT coalesce(json_agg(x ORDER BY x.played_at DESC), '[]'::json) AS body
  FROM (SELECT mt.id, g.slug AS game, mt.status, mt.reason, mt.played_at
          FROM match_seats s
          JOIN matches mt ON mt.id = s.match_id
          JOIN games g ON g.id = mt.game_id
         WHERE s.version_id = ($1)::uuid AND mt.status IN ('finished', 'rated')
         ORDER BY mt.played_at DESC LIMIT ($2)::int) x;

-- Soma's per-match rating change (§7.2): the events a match produced, by seat and ladder.
PREPARE s_match_change (uuid) AS
SELECT seat, ladder, mu_before, sigma_before, mu_after, sigma_after
  FROM rating_events WHERE match_id = ($1)::uuid ORDER BY seat, ladder;

-- the chain audit (§3.5): every event starts where the previous one on its ladder ended.
PREPARE a_chain AS
SELECT e.version_id, e.ladder, e.seq
  FROM rating_events e
  JOIN rating_events p ON p.version_id = e.version_id AND p.ladder = e.ladder AND p.seq = e.seq - 1
 WHERE e.mu_before IS DISTINCT FROM p.mu_after OR e.sigma_before IS DISTINCT FROM p.sigma_after;


-- ---------------------------------------------------------------- docs/clocks.md's SQL
-- the demand view (02 §4): state, cap and want per version
PREPARE d_demand (uuid, int, int, float8) AS
WITH live AS (
    SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), v AS (
    SELECT md.id AS model_id, md.weight_class,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM model_versions md
      JOIN live   ON live.id = md.season_id
      LEFT JOIN ratings r ON r.version_id = md.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM model_versions o
           WHERE o.season_id = md.season_id AND o.status = 'active'
             AND o.weight_class = md.weight_class AND o.id <> md.id
      ) reach ON true
     WHERE md.status = 'active'
     GROUP BY md.id, md.weight_class
), f AS (
    SELECT s.version_id AS model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.version_id
), w AS (
    SELECT v.model_id, v.weight_class, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.played < ($2)::int         THEN 'placement'
                WHEN v.sigma  > ($4)::float8      THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.played < ($2)::int         THEN ($2)::int
                WHEN v.sigma  > ($4)::float8      THEN ($3)::int
                ELSE                                   0 END AS cap
      FROM v LEFT JOIN f ON f.model_id = v.model_id
)
SELECT model_id, weight_class, state, sigma, played, in_flight,
       greatest(cap - in_flight, 0) AS want
  FROM w
 ORDER BY want DESC, sigma DESC, model_id;


-- the trial insert's read (02 §6.4), with the seat count coming from the preset (decision 14):
-- a two-seat map seats one baseline, a four-seat map three, and a map needing more baselines than
-- exist is left unpaired rather than seated short. Taken verbatim from what the package ships.
PREPARE p_trials AS
WITH cand AS ( SELECT c.id, c.game_id, c.season_id, c.model_id, c.weight_class, e.owner_id, s.rules, (SELECT count(*) FROM matches x WHERE x.trial_version_id = c.id) AS trials FROM model_versions c JOIN models e ON e.id = c.model_id JOIN seasons s ON s.id = c.season_id WHERE c.game_id = ($1)::uuid AND c.status = 'verified' AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id AND l.status IN ('pending', 'claimed', 'running')) ), pick AS ( SELECT cand.*, p.name AS preset, p.players FROM cand CROSS JOIN LATERAL ( SELECT coalesce( (SELECT jsonb_agg(g.value) FROM jsonb_array_elements(($3)::jsonb) AS g (value) WHERE cand.rules -> 'pairing' -> 'presets' IS NULL OR coalesce(g.value ->> 'name', g.value #>> '{}') IN ( SELECT coalesce(sp.value ->> 'name', sp.value #>> '{}') FROM jsonb_array_elements(cand.rules -> 'pairing' -> 'presets') AS sp (value))), ($3)::jsonb) AS list ) sel JOIN LATERAL ( SELECT coalesce(e.value ->> 'name', e.value #>> '{}') AS name, coalesce((e.value ->> 'players')::int, 2) AS players FROM jsonb_array_elements(sel.list) WITH ORDINALITY AS e (value, ord) WHERE e.ord = 1 + (cand.trials % greatest(jsonb_array_length(sel.list), 1)) ) p ON true WHERE cand.trials < coalesce((cand.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int) ), seated AS ( SELECT pick.id AS trial_version_id, pick.preset, pick.players, jsonb_build_array(pick.id) || coalesce(opp.ids, '[]'::jsonb) AS seats FROM pick LEFT JOIN LATERAL ( SELECT jsonb_agg(b.id ORDER BY b.rn) AS ids FROM (SELECT DISTINCT ON (be.owner_id) b.id, be.owner_id, row_number() OVER ( ORDER BY (b.weight_class = pick.weight_class) DESC, (SELECT count(*) FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE s.version_id = b.id AND m.status IN ('pending', 'claimed', 'running')), b.id) AS rn FROM model_versions b JOIN models be ON be.id = b.model_id JOIN users ub ON ub.id = be.owner_id AND ub.role = 'baseline' WHERE b.game_id = pick.game_id AND b.season_id = pick.season_id AND b.status = 'active' ORDER BY be.owner_id, b.id) b WHERE b.rn < pick.players ) opp ON true ) SELECT json_build_object('n', count(*), 'pairings', coalesce(json_agg(json_build_object( 'seats', seats, 'trial', trial_version_id, 'preset', preset, 'seed', (random() * 2147483647)::bigint)), '[]'::json)) AS body FROM seated WHERE jsonb_array_length(seats) = players;


-- count's batch as one document (02 §5.1): the folds it will apply, then the trials it will
-- decide, in one read so the workflow's loop walks a single array.
PREPARE c_batch_doc AS
WITH folds AS ( SELECT json_build_object('kind', 'fold', 'id', m.id) AS item, 0 AS grp, m.played_at AS ord, m.id FROM matches m WHERE m.status = 'finished' AND m.trial_version_id IS NULL ORDER BY m.played_at, m.id LIMIT ($1)::int ), verdicts AS ( SELECT json_build_object( 'kind', 'verdict', 'model_id', c.id, 'trial_id', t.id, 'predecessor_id', (SELECT p.id FROM model_versions p WHERE p.model_id = c.model_id AND p.season_id = c.season_id AND p.status = 'active'), 'trials', n.trials, 'decision', CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN 'pass' WHEN t.status = 'finished' THEN 'reject' WHEN t.status = 'failed' AND t.fault_seat = cs.seat THEN 'reject' WHEN n.trials >= tm.trials_max THEN 'reject' ELSE 'repair' END, 'reason', CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN NULL WHEN t.status = 'finished' THEN 'FORFEIT' WHEN t.status = 'failed' AND t.fault_seat = cs.seat THEN 'FAULT:' || t.fault_reason WHEN n.trials >= tm.trials_max THEN 'UNPLAYABLE' ELSE NULL END) AS item, 1 AS grp, t.played_at AS ord, c.id FROM model_versions c JOIN seasons cse ON cse.id = c.season_id CROSS JOIN LATERAL (SELECT coalesce((cse.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int) AS trials_max) tm JOIN LATERAL (SELECT t.* FROM matches t WHERE t.trial_version_id = c.id AND t.status IN ('finished', 'failed', 'cancelled') ORDER BY t.created_at DESC LIMIT 1) t ON true JOIN match_seats cs ON cs.match_id = t.id AND cs.version_id = c.id JOIN LATERAL (SELECT count(*) AS trials FROM matches x WHERE x.trial_version_id = c.id) n ON true WHERE c.status = 'verified' AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id AND l.status IN ('pending', 'claimed', 'running')) ) SELECT json_build_object('n', count(*), 'items', coalesce(json_agg(item ORDER BY grp, ord, id), '[]'::json)) AS body FROM (SELECT * FROM folds UNION ALL SELECT * FROM verdicts) x;

-- pair's whole read (02 §6.1): the demand view, who may be seated opposite, the presets each
-- version has played, the queue depth and the room, as one document taken at one instant.
PREPARE p_demand_doc AS
WITH live AS ( SELECT id, rules FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL ), lim AS ( SELECT coalesce((live.rules -> 'pairing' ->> 'burst')::int, ($2)::int) AS burst, coalesce((live.rules -> 'pairing' ->> 'steady_cap')::int, ($3)::int) AS steady_cap, coalesce((live.rules -> 'rating' ->> 'settled_sigma')::float8, ($4)::float8) AS settled_sigma, coalesce((live.rules -> 'pairing' ->> 'cross_class_fraction')::float8, ($6)::float8) AS cross_class_fraction, coalesce((live.rules -> 'pairing' ->> 'self_pairing')::bool, false) AS self_pairing, (live.rules -> 'pairing' ->> 'queue_share_max')::int AS queue_share_max, live.rules -> 'pairing' -> 'presets' AS presets FROM live ), v AS ( SELECT vv.id AS model_id, e.owner_id, vv.weight_class, max(r.sigma) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma, min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played FROM model_versions vv JOIN models e ON e.id = vv.model_id JOIN live ON live.id = vv.season_id LEFT JOIN ratings r ON r.version_id = vv.id LEFT JOIN LATERAL ( SELECT count(*) AS n FROM model_versions o WHERE o.season_id = vv.season_id AND o.status = 'active' AND o.weight_class = vv.weight_class AND o.id <> vv.id ) reach ON true WHERE vv.status = 'active' GROUP BY vv.id, e.owner_id, vv.weight_class ), f AS ( SELECT s.version_id AS model_id, count(*) AS in_flight FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished') GROUP BY s.version_id ), w AS ( SELECT v.model_id, v.owner_id, v.weight_class, v.sigma, v.played, coalesce(f.in_flight, 0) AS in_flight, CASE WHEN v.played < lim.burst THEN 'placement' WHEN v.sigma > lim.settled_sigma THEN 'unsettled' ELSE 'settled' END AS state, CASE WHEN v.played < lim.burst THEN lim.burst WHEN v.sigma > lim.settled_sigma THEN lim.steady_cap ELSE 0 END AS cap FROM v CROSS JOIN lim LEFT JOIN f ON f.model_id = v.model_id ), owner_load AS ( SELECT e.owner_id, count(*) AS in_flight FROM match_seats st JOIN matches m ON m.id = st.match_id JOIN model_versions o ON o.id = st.version_id JOIN models e ON e.id = o.model_id WHERE m.game_id = ($1)::uuid AND m.trial_version_id IS NULL AND m.status IN ('pending', 'claimed', 'running', 'finished') GROUP BY e.owner_id ), wants AS ( SELECT w.model_id, w.owner_id, w.weight_class, w.state, w.sigma, w.played, w.in_flight, greatest(least( greatest(w.cap - w.in_flight, 0), coalesce(lim.queue_share_max, 2147483647) - coalesce(ol.in_flight, 0) - coalesce(sum(greatest(w.cap - w.in_flight, 0)) OVER ( PARTITION BY w.owner_id ORDER BY greatest(w.cap - w.in_flight, 0) DESC, w.model_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) ), 0) AS want FROM w CROSS JOIN lim LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id ), pool AS ( SELECT vv.id AS model_id, e.owner_id, vv.weight_class, (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma) ORDER BY r.ladder) FROM ratings r WHERE r.version_id = vv.id) AS ratings FROM model_versions vv JOIN models e ON e.id = vv.model_id JOIN live ON live.id = vv.season_id WHERE vv.status = 'active' ), played AS ( SELECT s.version_id AS model_id, m.preset, count(*) AS n FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated') GROUP BY s.version_id, m.preset ), depth AS ( SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending' ) SELECT json_build_object( 'demand', (SELECT coalesce(sum(want), 0) FROM wants), 'depth', (SELECT pending FROM depth), 'room', greatest(least((SELECT coalesce(sum(want), 0) FROM wants), ($5)::int - (SELECT pending FROM depth)), 0), 'wants', (SELECT coalesce(json_agg(wants ORDER BY want DESC, sigma DESC), '[]'::json) FROM wants WHERE want > 0), 'pool', (SELECT coalesce(json_agg(pool), '[]'::json) FROM pool), 'played', (SELECT coalesce(json_agg(played), '[]'::json) FROM played), 'limits', (SELECT json_build_object( 'self_pairing', lim.self_pairing, 'cross_class_fraction', lim.cross_class_fraction, 'presets', lim.presets) FROM lim), 'owners', (SELECT coalesce(json_agg(json_build_object( 'owner_id', o.owner_id, 'in_flight', o.in_flight, 'room', greatest(lim.queue_share_max - o.in_flight, 0))), '[]'::json) FROM (SELECT DISTINCT w.owner_id, coalesce(max(ol.in_flight), 0) AS in_flight FROM w LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id GROUP BY w.owner_id) o, lim WHERE lim.queue_share_max IS NOT NULL)) AS body;

PREPARE p_game AS
SELECT id FROM games WHERE slug = ($1)::text;
