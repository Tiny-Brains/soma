-- Every statement docs/schema.md §4-§7 and jodi/docs/rating-and-seasons.md §6 specify, PREPAREd so
-- Postgres parses and plans each, then EXECUTEd by scenario.sql and the race files. The statements
-- a season touches are taken from jodi/scripts/gen-jodi.py's text, so this harness walks what ships.
-- Parameter types are the casts those documents use.

PREPARE k_reap AS
UPDATE matches
   SET status           = CASE WHEN lapses + 1 >= 3 THEN 'failed' ELSE 'pending' END::match_status,
       lapses           = lapses + 1,
       claim_token      = NULL,
       lease_expires_at = NULL,
       fault_reason     = CASE WHEN lapses + 1 >= 3 THEN 'LEASE_LAPSED' END,
       closed_at        = CASE WHEN lapses + 1 >= 3 THEN now() END
 WHERE status IN ('claimed', 'running')
   AND lease_expires_at < now();

PREPARE k_claim (text, text[], int, uuid, int) AS
WITH first AS MATERIALIZED (
    SELECT m.id, m.preset
      FROM matches m
     WHERE m.status = 'pending' AND m.engine_digest = ($1)::text
     ORDER BY (m.trial_model_id IS NOT NULL) DESC,
              EXISTS (SELECT 1 FROM match_seats s
                       WHERE s.match_id = m.id
                         AND s.weights_hash = ANY (($2)::text[])) DESC,
              m.created_at, m.id
     LIMIT 1
       FOR UPDATE SKIP LOCKED
), wave AS MATERIALIZED (
    SELECT m.id
      FROM matches m, first f
     WHERE m.status = 'pending' AND m.engine_digest = ($1)::text
       AND m.preset = f.preset
       AND (m.id = f.id
            OR EXISTS (SELECT 1 FROM match_seats a
                         JOIN match_seats b ON b.weights_hash = a.weights_hash
                        WHERE a.match_id = f.id AND b.match_id = m.id))
     ORDER BY (m.id = f.id) DESC, (m.trial_model_id IS NOT NULL) DESC, m.created_at, m.id
     LIMIT ($3)::int
       FOR UPDATE OF m SKIP LOCKED
)
UPDATE matches m
   SET status           = 'claimed',
       claim_token      = ($4)::uuid,
       lease_expires_at = now() + ($5)::int * interval '1 second'
  FROM wave
 WHERE m.id = wave.id;

PREPARE k_read (uuid) AS
SELECT json_build_object(
         'id', m.id, 'seed', m.seed, 'preset', m.preset, 'trial_model_id', m.trial_model_id,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.model_id,
                      'weights_hash', s.weights_hash, 'adapter_hash', s.adapter_hash)
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row
  FROM matches m
 WHERE m.claim_token = ($1)::uuid AND m.status = 'claimed'
 ORDER BY m.id;

PREPARE k_start (uuid, uuid[]) AS
UPDATE matches SET status = 'running'
 WHERE claim_token = ($1)::uuid AND status = 'claimed' AND id = ANY (($2)::uuid[]);

PREPARE k_release (uuid, uuid[], int) AS
UPDATE matches
   SET status           = CASE WHEN refusals + 1 >= ($3)::int THEN 'failed' ELSE 'pending' END::match_status,
       refusals         = refusals + 1,
       claim_token      = NULL,
       lease_expires_at = NULL,
       fault_reason     = CASE WHEN refusals + 1 >= ($3)::int THEN 'UNLOADABLE' END,
       closed_at        = CASE WHEN refusals + 1 >= ($3)::int THEN now() END
 WHERE claim_token = ($1)::uuid AND status = 'claimed' AND id = ANY (($2)::uuid[]);

PREPARE k_fail (uuid, uuid, text, smallint, text, text) AS
UPDATE matches
   SET status               = 'failed',
       fault_reason         = ($3)::text,
       fault_seat           = ($4)::smallint,
       closed_at            = now(),
       engine_digest_played = ($5)::text,
       evaluator_digest     = ($6)::text,
       lease_expires_at     = NULL
 WHERE claim_token = ($1)::uuid AND id = ($2)::uuid AND status IN ('claimed', 'running');

PREPARE k_renew (uuid, int) AS
UPDATE matches
   SET lease_expires_at = now() + ($2)::int * interval '1 second'
 WHERE claim_token = ($1)::uuid AND status = 'running';

PREPARE k_finish (uuid, uuid, jsonb, text, int, int, text, text, text) AS
WITH m AS (
    UPDATE matches
       SET status               = 'finished',
           reason               = ($4)::text,
           turns                = ($5)::int,
           played_ms            = ($6)::int,
           engine_digest_played = ($7)::text,
           evaluator_digest     = ($8)::text,
           replay_key           = ($9)::text,
           played_at            = now(),
           lease_expires_at     = NULL
     WHERE id = ($2)::uuid AND claim_token = ($1)::uuid AND status = 'running'
       AND (SELECT count(DISTINCT v.seat)
              FROM jsonb_to_recordset(($3)::jsonb) AS v (seat smallint)
             WHERE v.seat BETWEEN 0 AND seat_count - 1) = seat_count
 RETURNING id
)
UPDATE match_seats s
   SET rank = v.rank, score = v.score, strikes = v.strikes
  FROM m,
       jsonb_to_recordset(($3)::jsonb) AS v (seat smallint, rank smallint, score int, strikes smallint)
 WHERE s.match_id = m.id AND s.seat = v.seat;

PREPARE c_fence (timestamptz, int) AS
UPDATE clocks
   SET scheduled_for = ($1)::timestamptz, attempt = ($2)::int, updated_at = now()
 WHERE key = 'count'
   AND (scheduled_for, attempt) < (($1)::timestamptz, ($2)::int);

PREPARE c_batch (int) AS
SELECT id FROM matches WHERE status = 'finished' ORDER BY played_at, id LIMIT ($1)::int;

PREPARE c_priors (uuid) AS
SELECT json_build_object(
         'id', m.id, 'trial_model_id', m.trial_model_id, 'ladders', m.ladders,
         'seat_count', m.seat_count,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.model_id, 'rank', s.rank, 'strikes', s.strikes,
                      'ratings', (SELECT json_agg(json_build_object(
                                            'ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                                          ORDER BY r.ladder)
                                    FROM ratings r
                                   WHERE r.model_id = s.model_id AND r.ladder = ANY (m.ladders)))
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row
  FROM matches m
 WHERE m.id = ($1)::uuid AND m.status = 'finished';

PREPARE c_fold (timestamptz, int, uuid, jsonb) AS
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
       AND m.trial_model_id IS NULL
       AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders)
 RETURNING m.id
), post AS (
    SELECT p.*
      FROM mark,
           jsonb_to_recordset(($4)::jsonb)
             AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8)
), applied AS (
    UPDATE ratings r
       SET mu = post.mu, sigma = post.sigma,
           matches_played = r.matches_played + 1, updated_at = now()
      FROM post, ratings old
     WHERE r.model_id = post.model_id AND r.ladder = post.ladder::ladder
       AND old.model_id = r.model_id AND old.ladder = r.ladder
 RETURNING r.model_id, r.ladder, r.matches_played AS seq, post.seat,
           old.mu AS mu_before, old.sigma AS sigma_before, r.mu AS mu_after, r.sigma AS sigma_after
)
INSERT INTO rating_events (model_id, ladder, seq, match_id, seat,
                           mu_before, sigma_before, mu_after, sigma_after)
SELECT a.model_id, a.ladder, a.seq, mark.id, a.seat,
       a.mu_before, a.sigma_before, a.mu_after, a.sigma_after
  FROM applied a, mark;

PREPARE c_verdicts AS
SELECT json_build_object('model_id', c.id, 'owner_id', c.owner_id, 'game_id', c.game_id,
         'trials', (SELECT count(*) FROM matches t WHERE t.trial_model_id = c.id),
         'last', (SELECT json_build_object('id', t.id, 'status', t.status,
                          'fault_seat', t.fault_seat, 'fault_reason', t.fault_reason,
                          'candidate_seat', cs.seat, 'candidate_rank', cs.rank,
                          'candidate_strikes', cs.strikes)
                    FROM matches t
                    JOIN match_seats cs ON cs.match_id = t.id AND cs.model_id = c.id
                   WHERE t.trial_model_id = c.id
                   ORDER BY t.created_at DESC LIMIT 1)) AS row
  FROM models c
 WHERE c.status = 'verified'
   AND EXISTS (SELECT 1 FROM matches t WHERE t.trial_model_id = c.id
                AND t.status IN ('finished', 'failed', 'cancelled'));

PREPARE c_pass (timestamptz, int, uuid, uuid, float8, float8, float8) AS
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
      FROM seasons s JOIN models c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_model_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), pred AS (
    UPDATE models p SET status = 'superseded'
      FROM bump, models cand
     WHERE cand.id = ($4)::uuid
       AND p.owner_id = cand.owner_id AND p.game_id = cand.game_id
       AND p.season_id = cand.season_id AND p.status = 'active'        -- within the season
 RETURNING p.id
), cand AS (
    UPDATE models c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
       AND (SELECT count(*) FROM pred) >= 0
 RETURNING c.id, c.weight_class
), seeded AS (
    INSERT INTO ratings (model_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, ($5)::float8),
           coalesce(seed.sigma, ($6)::float8),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.model_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * ($7)::float8, ($6)::float8) END AS sigma
      ) seed
 RETURNING model_id, ladder, mu, sigma
)
INSERT INTO rating_events (model_id, ladder, seq, mu_after, sigma_after)
SELECT model_id, ladder, 0, mu, sigma FROM seeded;


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
      FROM seasons s JOIN models c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_model_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), cand AS (
    UPDATE models c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
 RETURNING c.id, c.weight_class, c.owner_id, c.game_id, c.season_id
), pred AS (
    UPDATE models p SET status = 'superseded'
      FROM bump, cand
     WHERE p.owner_id = cand.owner_id AND p.game_id = cand.game_id
       AND p.season_id = cand.season_id
       AND p.status = 'active' AND p.id <> cand.id
 RETURNING p.id
), seeded AS (
    INSERT INTO ratings (model_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, ($5)::float8),
           coalesce(seed.sigma, ($6)::float8),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.model_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * ($7)::float8, ($6)::float8) END AS sigma
      ) seed
 RETURNING model_id, ladder, mu, sigma
)
INSERT INTO rating_events (model_id, ladder, seq, mu_after, sigma_after)
SELECT model_id, ladder, 0, mu, sigma FROM seeded;

PREPARE c_reject (timestamptz, int, uuid, uuid, text) AS
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM fence
     WHERE c.key = 'roster' AND (SELECT count(*) FROM mark) >= 0
 RETURNING c.epoch
)
UPDATE models md
   SET status = 'rejected', reject_reason = ($5)::text
  FROM bump
 WHERE md.id = ($4)::uuid AND md.status = 'verified';

PREPARE c_withdraw_pred (uuid, uuid) AS
UPDATE matches m
   SET status = 'cancelled', withdrawn_reason = 'SUPERSEDED',
       successor_id = ($2)::uuid, closed_at = now()
 WHERE m.status = 'pending'
   AND EXISTS (SELECT 1 FROM match_seats s WHERE s.match_id = m.id AND s.model_id = ($1)::uuid);

PREPARE p_epoch AS
SELECT epoch FROM clocks WHERE key = 'roster';

PREPARE p_insert (bigint, text, bigint, text, uuid[], uuid, uuid) AS
WITH season AS (
    -- 06 §6.1: the live season supplies the digest and is what every seat must belong to. No live
    -- season, or a seat from another season, and nothing is inserted -- pair halts and re-reads.
    SELECT s.id, s.game_id, s.engine_digest
      FROM seasons s
      JOIN games g ON g.id = s.game_id AND g.slug = ($2)::text
     WHERE s.closed_at IS NULL
), seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, md.id AS model_id, md.weights_hash, md.adapter_hash, md.weight_class
      FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (model_id, ord)
      JOIN models md ON md.id = seat.model_id
      JOIN season    ON season.id = md.season_id
     WHERE md.status = 'active'
        OR (md.status = 'verified' AND md.id = ($6)::uuid)
), m AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders,
                         trial_model_id, pairing_id)
    SELECT season.game_id, season.id, season.engine_digest, ($3)::bigint, ($4)::text,
           cardinality(($5)::uuid[]),
           CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[]
                WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1
                     THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[]
                ELSE ARRAY['open']::ladder[]
           END,
           ($6)::uuid, ($7)::uuid
      FROM season
      JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence
        ON true
     WHERE (SELECT count(*) FROM seated) = cardinality(($5)::uuid[])
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, model_id, weights_hash, adapter_hash, paired_ratings)
SELECT m.id, s.seat, s.model_id, s.weights_hash, s.adapter_hash,
       (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                         ORDER BY r.ladder)
          FROM ratings r WHERE r.model_id = s.model_id)
  FROM m, seated s;

PREPARE w_sweep AS
UPDATE matches m
   SET status = 'cancelled', closed_at = now(),
       withdrawn_reason =
           CASE WHEN s.closed_at IS NOT NULL            THEN 'SEASON_CLOSED'
                WHEN m.engine_digest <> s.engine_digest THEN 'ENGINE_RETIRED'
                ELSE (SELECT CASE md.status WHEN 'superseded' THEN 'SUPERSEDED'
                                            WHEN 'rejected'   THEN 'REJECTED'
                                            ELSE 'SEAT_LEFT' END
                        FROM match_seats st
                        JOIN models md ON md.id = st.model_id
                       WHERE st.match_id = m.id
                         AND NOT (md.status = 'active'
                               OR (md.status = 'verified' AND md.id = m.trial_model_id))
                       ORDER BY st.seat LIMIT 1)
           END,
       successor_id =
           (SELECT succ.id
              FROM match_seats st
              JOIN models gone ON gone.id = st.model_id AND gone.status = 'superseded'
              JOIN models succ ON succ.owner_id = gone.owner_id AND succ.game_id = gone.game_id
                              AND succ.season_id = gone.season_id AND succ.status = 'active'
             WHERE st.match_id = m.id
             ORDER BY st.seat LIMIT 1)
  FROM seasons s
 WHERE s.id = m.season_id AND m.status = 'pending'
   AND (s.closed_at IS NOT NULL
     OR m.engine_digest <> s.engine_digest
     OR EXISTS (SELECT 1 FROM match_seats st
                  JOIN models md ON md.id = st.model_id
                 WHERE st.match_id = m.id
                   AND NOT (md.status = 'active'
                         OR (md.status = 'verified' AND md.id = m.trial_model_id))));


-- Soma's history read under the two-table shape (§7.2): a plain join, no containment.
PREPARE s_history (uuid, int) AS
SELECT coalesce(json_agg(x ORDER BY x.played_at DESC), '[]'::json) AS body
  FROM (SELECT mt.id, g.slug AS game, mt.status, mt.reason, mt.played_at
          FROM match_seats s
          JOIN matches mt ON mt.id = s.match_id
          JOIN games g ON g.id = mt.game_id
         WHERE s.model_id = ($1)::uuid AND mt.status IN ('finished', 'rated')
         ORDER BY mt.played_at DESC LIMIT ($2)::int) x;

-- Soma's per-match rating change (§7.2): the events a match produced, by seat and ladder.
PREPARE s_match_change (uuid) AS
SELECT seat, ladder, mu_before, sigma_before, mu_after, sigma_after
  FROM rating_events WHERE match_id = ($1)::uuid ORDER BY seat, ladder;

-- the chain audit (§3.5): every event starts where the previous one on its ladder ended.
PREPARE a_chain AS
SELECT e.model_id, e.ladder, e.seq
  FROM rating_events e
  JOIN rating_events p ON p.model_id = e.model_id AND p.ladder = e.ladder AND p.seq = e.seq - 1
 WHERE e.mu_before IS DISTINCT FROM p.mu_after OR e.sigma_before IS DISTINCT FROM p.sigma_after;


-- ---------------------------------------------------------------- jodi/docs/design.md's SQL (jodi/docs/design.md)
-- the demand view (02 §4): state, cap and want per version
PREPARE d_demand (uuid, int, int, float8) AS
WITH live AS (
    SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), v AS (
    SELECT md.id AS model_id, md.weight_class, u.role,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM models md
      JOIN users u ON u.id = md.owner_id
      JOIN live   ON live.id = md.season_id
      LEFT JOIN ratings r ON r.model_id = md.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM models o
           WHERE o.season_id = md.season_id AND o.status = 'active'
             AND o.weight_class = md.weight_class AND o.id <> md.id
      ) reach ON true
     WHERE md.status = 'active'
     GROUP BY md.id, md.weight_class, u.role
), f AS (
    SELECT s.model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.model_id
), w AS (
    SELECT v.model_id, v.weight_class, v.role, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.role = 'baseline'          THEN 'baseline'
                WHEN v.played < ($2)::int         THEN 'placement'
                WHEN v.sigma  > ($4)::float8      THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.role = 'baseline'          THEN 0
                WHEN v.played < ($2)::int         THEN ($2)::int
                WHEN v.sigma  > ($4)::float8      THEN ($3)::int
                ELSE                                   0 END AS cap
      FROM v LEFT JOIN f ON f.model_id = v.model_id
)
SELECT model_id, weight_class, role, state, sigma, played, in_flight,
       greatest(cap - in_flight, 0) AS want
  FROM w
 ORDER BY want DESC, sigma DESC, model_id;


-- the verdict read (02 §5.1): the decision computed in SQL
PREPARE c_decide (int, int) AS
SELECT c.id AS model_id, c.version, t.id AS trial_id, t.status AS trial_status, n.trials,
       CASE WHEN t.status = 'finished' AND cs.strikes < ($1)::int THEN 'pass'
            WHEN t.status = 'finished'                          THEN 'reject'
            WHEN t.status = 'failed' AND t.fault_seat = cs.seat  THEN 'reject'
            WHEN n.trials >= ($2)::int                           THEN 'reject'
            ELSE 'repair' END AS decision,
       CASE WHEN t.status = 'finished' AND cs.strikes < ($1)::int THEN NULL
            WHEN t.status = 'finished'                          THEN 'FORFEIT'
            WHEN t.status = 'failed' AND t.fault_seat = cs.seat  THEN 'FAULT:' || t.fault_reason
            WHEN n.trials >= ($2)::int                           THEN 'UNPLAYABLE'
            ELSE NULL END AS reason
  FROM models c
  JOIN LATERAL (SELECT t.* FROM matches t
                 WHERE t.trial_model_id = c.id
                   AND t.status IN ('finished', 'failed', 'cancelled')
                 ORDER BY t.created_at DESC LIMIT 1) t ON true
  JOIN match_seats cs ON cs.match_id = t.id AND cs.model_id = c.id
  JOIN LATERAL (SELECT count(*) AS trials FROM matches x WHERE x.trial_model_id = c.id) n ON true
 WHERE c.status = 'verified'
   AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_model_id = c.id
                      AND l.status IN ('pending', 'claimed', 'running'));

-- the trial insert's read (02 §6.4), with the seat count coming from the preset (decision 14):
-- a two-seat map seats one baseline, a four-seat map three, and a map needing more baselines than
-- exist is left unpaired rather than seated short. Taken verbatim from what the package ships.
PREPARE p_trials (uuid, int, jsonb) AS
WITH cand AS (
    SELECT c.id, c.game_id, c.season_id, c.owner_id, c.weight_class,
           (SELECT count(*) FROM matches x WHERE x.trial_model_id = c.id) AS trials
      FROM models c
     WHERE c.game_id = ($1)::uuid AND c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_model_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running'))
), pick AS (
    SELECT cand.*, p.name AS preset, p.players
      FROM cand
      JOIN LATERAL (
          -- A preset is either { name, players } or a bare string, which means two seats. On a
          -- bare string `->> 'name'` is NULL, so `#>> '{}'` -- the whole scalar as text -- is the
          -- fallback. Getting this wrong is silent: the pairing still lands, with a null preset.
          SELECT coalesce(e.value ->> 'name', e.value #>> '{}') AS name,
                 coalesce((e.value ->> 'players')::int, 2) AS players
            FROM jsonb_array_elements(($3)::jsonb) WITH ORDINALITY AS e (value, ord)
           WHERE e.ord = 1 + (cand.trials % greatest(jsonb_array_length(($3)::jsonb), 1))
      ) p ON true
     WHERE cand.trials < ($2)::int
), seated AS (
    SELECT pick.id AS trial_model_id, pick.preset, pick.players,
           jsonb_build_array(pick.id) || coalesce(opp.ids, '[]'::jsonb) AS seats
      FROM pick
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(b.id ORDER BY b.rn) AS ids
            FROM (SELECT b.id,
                         row_number() OVER (
                             ORDER BY (b.weight_class = pick.weight_class) DESC,
                                      (SELECT count(*) FROM match_seats s
                                         JOIN matches m ON m.id = s.match_id
                                        WHERE s.model_id = b.id
                                          AND m.status IN ('pending', 'claimed', 'running')),
                                      b.id) AS rn
                    FROM models b
                    JOIN users ub ON ub.id = b.owner_id AND ub.role = 'baseline'
                   WHERE b.game_id = pick.game_id AND b.season_id = pick.season_id   -- 06 §6.2
                     AND b.status = 'active') b
           WHERE b.rn < pick.players
      ) opp ON true
)
SELECT json_build_object('n', count(*), 'pairings', coalesce(json_agg(json_build_object(
         'seats', seats, 'trial', trial_model_id, 'preset', preset,
         'seed', (random() * 2147483647)::bigint)), '[]'::json)) AS body
  FROM seated
 WHERE jsonb_array_length(seats) = players;


-- count's batch as one document (02 §5.1): the folds it will apply, then the trials it will
-- decide, in one read so the workflow's loop walks a single array.
PREPARE c_batch_doc (int, int, int) AS
WITH folds AS (
    SELECT json_build_object('kind', 'fold', 'id', m.id) AS item, 0 AS grp, m.played_at AS ord, m.id
      FROM matches m
     WHERE m.status = 'finished' AND m.trial_model_id IS NULL
     ORDER BY m.played_at, m.id
     LIMIT ($1)::int
), verdicts AS (
    SELECT json_build_object(
             'kind', 'verdict', 'model_id', c.id, 'trial_id', t.id,
             'predecessor_id', (SELECT p.id FROM models p
                                 WHERE p.owner_id = c.owner_id AND p.game_id = c.game_id
                                   AND p.status = 'active'),
             'trials', n.trials,
             'decision', CASE WHEN t.status = 'finished' AND cs.strikes < ($2)::int THEN 'pass'
                              WHEN t.status = 'finished'                           THEN 'reject'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'reject'
                              WHEN n.trials >= ($3)::int                            THEN 'reject'
                              ELSE 'repair' END,
             'reason',   CASE WHEN t.status = 'finished' AND cs.strikes < ($2)::int THEN NULL
                              WHEN t.status = 'finished'                           THEN 'FORFEIT'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'FAULT:' || t.fault_reason
                              WHEN n.trials >= ($3)::int                            THEN 'UNPLAYABLE'
                              ELSE NULL END) AS item,
           1 AS grp, t.played_at AS ord, c.id
      FROM models c
      JOIN LATERAL (SELECT t.* FROM matches t
                     WHERE t.trial_model_id = c.id
                       AND t.status IN ('finished', 'failed', 'cancelled')
                     ORDER BY t.created_at DESC LIMIT 1) t ON true
      JOIN match_seats cs ON cs.match_id = t.id AND cs.model_id = c.id
      JOIN LATERAL (SELECT count(*) AS trials FROM matches x WHERE x.trial_model_id = c.id) n ON true
     WHERE c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_model_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running'))
)
SELECT json_build_object('n', count(*),
         'items', coalesce(json_agg(item ORDER BY grp, ord, id), '[]'::json)) AS body
  FROM (SELECT * FROM folds UNION ALL SELECT * FROM verdicts) x;

-- pair's whole read (02 §6.1): the demand view, who may be seated opposite, the presets each
-- version has played, the queue depth and the room, as one document taken at one instant.
PREPARE p_demand_doc (uuid, int, int, float8, int) AS
WITH live AS (
    -- 06 §6.3: only the live season's versions want anything or may be seated. No live season,
    -- no demand, nothing paired -- the paused state.
    SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), v AS (
    SELECT md.id AS model_id, md.weight_class, u.role,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM models md
      JOIN users u ON u.id = md.owner_id
      JOIN live   ON live.id = md.season_id
      LEFT JOIN ratings r ON r.model_id = md.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM models o
           WHERE o.season_id = md.season_id AND o.status = 'active'
             AND o.weight_class = md.weight_class AND o.id <> md.id
      ) reach ON true
     WHERE md.status = 'active'
     GROUP BY md.id, md.weight_class, u.role
), f AS (
    SELECT s.model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.model_id
), w AS (
    SELECT v.model_id, v.weight_class, v.role, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.role = 'baseline'     THEN 'baseline'
                WHEN v.played < ($2)::int    THEN 'placement'
                WHEN v.sigma  > ($4)::float8 THEN 'unsettled'
                ELSE                              'settled' END AS state,
           CASE WHEN v.role = 'baseline'     THEN 0
                WHEN v.played < ($2)::int    THEN ($2)::int
                WHEN v.sigma  > ($4)::float8 THEN ($3)::int
                ELSE                              0 END AS cap
      FROM v LEFT JOIN f ON f.model_id = v.model_id
), wants AS (
    SELECT model_id, weight_class, role, state, sigma, played, in_flight,
           greatest(cap - in_flight, 0) AS want
      FROM w
), pool AS (
    SELECT md.id AS model_id, md.weight_class, u.role,
           (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                            ORDER BY r.ladder) FROM ratings r WHERE r.model_id = md.id) AS ratings
      FROM models md JOIN users u ON u.id = md.owner_id
      JOIN live ON live.id = md.season_id
     WHERE md.status = 'active'
), played AS (
    SELECT s.model_id, m.preset, count(*) AS n
      FROM match_seats s JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated')
     GROUP BY s.model_id, m.preset
), depth AS (
    SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending'
)
SELECT json_build_object(
         'demand', (SELECT coalesce(sum(want), 0) FROM wants),
         'depth',  (SELECT pending FROM depth),
         'room',   greatest(least((SELECT coalesce(sum(want), 0) FROM wants),
                                  ($5)::int - (SELECT pending FROM depth)), 0),
         'wants',  (SELECT coalesce(json_agg(wants ORDER BY want DESC, sigma DESC), '[]'::json)
                      FROM wants WHERE want > 0),
         'pool',   (SELECT coalesce(json_agg(pool), '[]'::json) FROM pool),
         'played', (SELECT coalesce(json_agg(played), '[]'::json) FROM played)) AS body;

PREPARE p_game (text) AS SELECT id FROM games WHERE slug = ($1)::text;
