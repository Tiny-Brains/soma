-- docs/schema.md draft 3 — the walk, end to end, on the prepared statements.
-- Runs after statements.sql in the same session. Each EXECUTE is its own
-- transaction, as it would be from an Orion task. Match ids are captured with
-- \gset because EXECUTE parameters may not contain subqueries.
\set ON_ERROR_STOP off
\pset footer off

\echo '--- seed: game, users, models, ratings'
INSERT INTO games (id, slug, name, active_engine_digest)
VALUES ('00000000-0000-0000-0000-00000000000a', 'ants', 'Ants', 'sha256:e1');
INSERT INTO seasons (id, game_id, number, engine_digest, submissions_open_at, submissions_close_at)
VALUES ('50000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 1, 'sha256:e1',
        now() - interval '1 hour', now() + interval '1 day');
INSERT INTO users (id, github_id, handle, role) VALUES
  ('00000000-0000-0000-0000-0000000000b1', NULL, 'baseline-random', 'baseline'),
  ('00000000-0000-0000-0000-0000000000a1', 1,    'alice',           'competitor');
INSERT INTO models (id, owner_id, game_id, season_id, version, repo, release_tag, status, weight_class,
                    weights_hash, adapter_hash, evaluator_digest) VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000b1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'tb/baselines', 'random-v1', 'active', 'nano',
   'sha256:wb1', 'sha256:ab1', 'sha256:ev1'),
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'alice/ants', 'v1', 'active', 'nano',
   'sha256:wa1', 'sha256:aa1', 'sha256:ev1'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 2, 'alice/ants', 'v2', 'verified', 'nano',
   'sha256:wa2', 'sha256:aa2', 'sha256:ev1');
INSERT INTO ratings (model_id, ladder, mu, sigma) VALUES
  ('10000000-0000-0000-0000-000000000001', 'nano', 25, 8.333),
  ('10000000-0000-0000-0000-000000000001', 'open', 25, 8.333),
  ('20000000-0000-0000-0000-000000000001', 'nano', 30, 4),
  ('20000000-0000-0000-0000-000000000001', 'open', 31, 3.5);

\echo '--- pair: epoch read; trial insert (expect INSERT 0 2 seats); ranked insert (expect 2); second live trial (expect unique violation)'
EXECUTE p_epoch;
EXECUTE p_insert (0, 'ants', 42, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid());
EXECUTE p_insert (0, 'ants', 43, 'default',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid());
EXECUTE p_insert (0, 'ants', 44, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid());
\echo '--- pair: stale epoch (expect 0); a row on another preset (expect 2)'
EXECUTE p_insert (99, 'ants', 45, 'default',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid());
EXECUTE p_insert (0, 'ants', 46, 'other-map',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid());
SELECT seed, preset, status, seat_count, ladders, trial_model_id IS NOT NULL AS trial FROM matches ORDER BY seed;
SELECT m.seed, s.seat, s.model_id, s.weights_hash, s.paired_ratings FROM match_seats s JOIN matches m ON m.id = s.match_id ORDER BY m.seed, s.seat;
SELECT id AS m42 FROM matches WHERE seed = 42 \gset
SELECT id AS m43 FROM matches WHERE seed = 43 \gset
SELECT id AS m46 FROM matches WHERE seed = 46 \gset

\echo '--- kalam: reap (expect 0); claim K=8 (expect 2: the trial first, then the same-preset row sharing the baseline)'
EXECUTE k_reap;
EXECUTE k_claim ('sha256:e1', '{}', 8, '30000000-0000-0000-0000-000000000001', 60);
EXECUTE k_read ('30000000-0000-0000-0000-000000000001');
\echo '--- kalam: a second replica claims what is left (expect 1: the other-preset row)'
EXECUTE k_claim ('sha256:e1', '{}', 8, '30000000-0000-0000-0000-000000000002', 60);
\echo '--- kalam: start (expect 2); renew (expect 2); renew with a foreign token (expect 0)'
EXECUTE k_start ('30000000-0000-0000-0000-000000000001', ARRAY[:'m42'::uuid, :'m43'::uuid]);
EXECUTE k_renew ('30000000-0000-0000-0000-000000000001', 60);
EXECUTE k_renew ('30000000-0000-0000-0000-000000000009', 60);
\echo '--- kalam: a malformed result naming one seat twice (expect 0, row still running); finish both rows (expect UPDATE 2 seats each); finish again (expect 0)'
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":0,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, 4000, 'sha256:e1', 'sha256:ev1', 'replays/ants/x/t1.json');
SELECT seed, status FROM matches WHERE seed = 42;
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, 4000, 'sha256:e1', 'sha256:ev1', 'replays/ants/x/t1.json');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, 6000, 'sha256:e1', 'sha256:ev1', 'replays/ants/y/t1.json');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, 6000, 'sha256:e1', 'sha256:ev1', 'replays/ants/y/t1.json');
SELECT m.seed, s.seat, s.rank, s.score, s.strikes FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.seed IN (42, 43) ORDER BY m.seed, s.seat;
\echo '--- kalam: the other replica lapses; reap after expiry (expect 1: back to pending, lapses 1, token cleared)'
UPDATE matches SET lease_expires_at = now() - interval '1 second' WHERE claim_token = '30000000-0000-0000-0000-000000000002';
EXECUTE k_reap;
SELECT seed, status, lapses, claim_token IS NULL AS token_cleared FROM matches WHERE seed = 46;

\echo '--- count: fence claim attempt 1 (expect 1); an older occurrence (expect 0); a retry, attempt 2 (expect 1)'
EXECUTE c_fence ('2026-09-07 10:00:00+00', 1);
EXECUTE c_fence ('2026-09-07 09:59:00+00', 1);
EXECUTE c_fence ('2026-09-07 10:00:00+00', 2);
\echo '--- count: batch (expect 2 ids); priors for the ranked row'
EXECUTE c_batch (10);
EXECUTE c_priors (:'m43');
\echo '--- count: fold under the stale fence (expect 0, row still finished); under the live fence (expect 4); again (expect 0); on the trial row (expect 0, row untouched)'
EXECUTE c_fold ('2026-09-07 10:00:00+00', 1, :'m43',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"nano","mu":29.2,"sigma":3.8},{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"open","mu":30.3,"sigma":3.4},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"nano","mu":27.9,"sigma":6.1},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":27.4,"sigma":6.2}]');
SELECT seed, status FROM matches WHERE seed = 43;
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m43',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"nano","mu":29.2,"sigma":3.8},{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"open","mu":30.3,"sigma":3.4},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"nano","mu":27.9,"sigma":6.1},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":27.4,"sigma":6.2}]');
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m43', '[]');
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m42', '[]');
SELECT seed, status, rated_seq FROM matches WHERE seed IN (42, 43) ORDER BY seed;
EXECUTE s_match_change (:'m43');
\echo '--- rating events: a duplicate seq is refused by the chain key (expect unique violation); the chain audit finds no break (expect 0 rows)'
INSERT INTO rating_events (model_id, ladder, seq, match_id, seat, mu_before, sigma_before, mu_after, sigma_after)
VALUES ('20000000-0000-0000-0000-000000000001', 'nano', 1, :'m43', 0, 30, 4, 29.2, 3.8);
EXECUTE a_chain;
SELECT model_id, ladder, mu, sigma, matches_played FROM ratings ORDER BY model_id, ladder;

\echo '--- count: verdict read (expect alice v2: trials 1, last finished, candidate_seat 0, candidate_rank 1)'
EXECUTE c_verdicts;
EXECUTE c_decide (5, 3);
\echo '--- count: pass under the live fence (expect INSERT 0 2); models_one_active_uniq must not fire'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
SELECT version, status FROM models WHERE owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY version;
SELECT model_id, ladder, mu, sigma, seed_mu, seed_sigma FROM ratings WHERE model_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder;
SELECT ladder, seq, match_id, mu_before, mu_after, sigma_after FROM rating_events WHERE model_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder, seq;
SELECT key, epoch FROM clocks WHERE key = 'roster';
SELECT seed, status, rated_seq FROM matches WHERE seed = 42;
\echo '--- count: pass again (expect INSERT 0 0)'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
\echo '--- promotion statement 2: withdraw the pending rows naming v1 (expect 1: the other-preset row, successor v2)'
EXECUTE c_withdraw_pred ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002');
SELECT seed, status, withdrawn_reason, successor_id FROM matches WHERE seed = 46;
\echo '--- pair with the epoch read before promotion (expect 0: fenced out); with the new epoch (expect 2)'
EXECUTE p_insert (0, 'ants', 47, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid());
EXECUTE p_insert (1, 'ants', 47, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid());
\echo '--- withdraw sweep: retire the engine on the live season (expect 1: seed 47 ENGINE_RETIRED); a closed season refuses inserts (expect 0) and the sweep finds nothing queued (expect 0)'
UPDATE games SET active_engine_digest = 'sha256:e2';
UPDATE seasons SET engine_digest = 'sha256:e2';
EXECUTE w_sweep;
SELECT seed, status, withdrawn_reason FROM matches WHERE seed = 47;
UPDATE seasons SET closed_at = now();
EXECUTE p_insert (1, 'ants', 48, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid());
EXECUTE w_sweep;
UPDATE seasons SET closed_at = NULL;

\echo '--- reject path: v3 verified; its trial fails with a fault on seat 0; verdict read; reject (expect UPDATE 1, epoch 2)'
INSERT INTO models (id, owner_id, game_id, season_id, version, repo, release_tag, status, weight_class,
                    weights_hash, adapter_hash, evaluator_digest) VALUES
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 3, 'alice/ants', 'v3', 'verified', 'nano',
   'sha256:wa3', 'sha256:aa3', 'sha256:ev1');
EXECUTE p_insert (1, 'ants', 50, 'default',
  '{20000000-0000-0000-0000-000000000003,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000003', gen_random_uuid());
SELECT id AS m50 FROM matches WHERE seed = 50 \gset
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000003', 60);
EXECUTE k_fail ('30000000-0000-0000-0000-000000000003', :'m50', 'HASH_MISMATCH', 0, 'sha256:e2', 'sha256:ev1');
EXECUTE c_verdicts;
EXECUTE c_decide (5, 3);
EXECUTE c_reject ('2026-09-07 10:00:00+00', 2, :'m50', '20000000-0000-0000-0000-000000000003', 'HASH_MISMATCH');
SELECT version, status, reject_reason FROM models WHERE version = 3;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '--- memory refusal: a ranked row claimed then released (expect 1; pending, refusals 1, lapses 0); at the ceiling (expect failed UNLOADABLE)'
EXECUTE p_insert (2, 'ants', 51, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid());
SELECT id AS m51 FROM matches WHERE seed = 51 \gset
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000004', 60);
EXECUTE k_release ('30000000-0000-0000-0000-000000000004', ARRAY[:'m51'::uuid], 5);
SELECT seed, status, refusals, lapses FROM matches WHERE seed = 51;
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000005', 60);
EXECUTE k_release ('30000000-0000-0000-0000-000000000005', ARRAY[:'m51'::uuid], 2);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 51;

\echo '--- soma: a version''s history is one join (expect the rated row 43 for alice v1; the cancelled row 46 is not listed)'
EXECUTE s_history ('20000000-0000-0000-0000-000000000001', 10);

\echo '--- the kalam role: withdraw (expect denied); fake cancelled (expect check violation); fake rated (expect denied); reseat (expect denied); rank without score (expect check violation); read both tables (ok); read models, read or write events (expect denied)'
EXECUTE p_insert (2, 'ants', 52, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid());
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
SET ROLE kalam;
UPDATE matches SET withdrawn_reason = 'x' WHERE seed = 52;
UPDATE matches SET status = 'cancelled', closed_at = now() WHERE seed = 52;
UPDATE matches SET status = 'rated', rated_at = now() WHERE seed = 52;
UPDATE match_seats SET model_id = '20000000-0000-0000-0000-000000000001' WHERE match_id = :'m52' AND seat = 0;
UPDATE match_seats SET rank = 1 WHERE match_id = :'m52' AND seat = 0;
SELECT count(*) AS kalam_reads_matches FROM matches;
SELECT count(*) AS kalam_reads_seats FROM match_seats;
SELECT count(*) FROM models;
SELECT count(*) FROM rating_events;
UPDATE rating_events SET mu_after = 0;
RESET ROLE;

\echo '--- final state'
SELECT seed, preset, status, lapses, refusals, withdrawn_reason, fault_reason, fault_seat, rated_seq FROM matches ORDER BY seed;

\echo '--- the adapter copy: stored as the exact text, accepted when it hashes to adapter_hash (expect INSERT 0 1); one byte changed (expect check violation)'
INSERT INTO models (id, owner_id, game_id, season_id, version, repo, release_tag, status, weight_class,
                    weights_hash, adapter_hash, evaluator_digest, adapter) VALUES
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 4, 'alice/ants', 'v4', 'verified', 'nano',
   'sha256:wa4', 'sha256:' || encode(sha256(convert_to('{"in": ["scatter"]}', 'UTF8')), 'hex'),
   'sha256:ev1', '{"in": ["scatter"]}');
UPDATE models SET adapter = '{"in": ["scatter"] }' WHERE version = 4;

\echo '--- jodi/docs/design.md: the trial read pairs v4 (verified, no live trial, 0 trials) with the nano baseline on preset 1 (expect n 1, 2 seats)'
EXECUTE p_trials ('00000000-0000-0000-0000-00000000000a', 3,
  '[{"name":"standard","players":2},{"name":"maze","players":2},{"name":"cell","players":2}]');
\echo '--- decision 14: the preset decides the seat count. Only one baseline exists here, so a 4-seat map is left unpaired rather than seated short (expect n 0)'
EXECUTE p_trials ('00000000-0000-0000-0000-00000000000a', 3, '[{"name":"melee","players":4}]');
\echo '--- and a bare-string preset still means two seats (expect n 1)'
EXECUTE p_trials ('00000000-0000-0000-0000-00000000000a', 3, '["legacy"]');
\echo '--- promotion in the reverse order: v4 activated before v2 is demoted, under the deferred one-active constraint (expect INSERT 0 2; v2 superseded, v4 active; epoch 3)'
EXECUTE p_insert (2, 'ants', 60, 'default',
  '{20000000-0000-0000-0000-000000000004,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000004', gen_random_uuid());
SELECT id AS m60 FROM matches WHERE seed = 60 \gset
EXECUTE k_claim ('sha256:e2', '{}', 1, '30000000-0000-0000-0000-000000000007', 60);
EXECUTE k_start ('30000000-0000-0000-0000-000000000007', ARRAY[:'m60'::uuid]);
EXECUTE k_finish ('30000000-0000-0000-0000-000000000007', :'m60',
  '[{"seat":0,"rank":1,"score":8,"strikes":0},{"seat":1,"rank":2,"score":2,"strikes":0}]',
  'all_food', 90, 2500, 'sha256:e2', 'sha256:ev1', 'replays/ants/w/t7.json');
EXECUTE c_pass_reversed ('2026-09-07 10:00:00+00', 2, :'m60', '20000000-0000-0000-0000-000000000004', 25, 8.333, 2.0);
SELECT version, status FROM models WHERE owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY version;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '--- jodi/docs/design.md: the trial read now finds nothing (v4 active); the demand view over the final roster (burst 8, steady 2, settled 3.0)'
EXECUTE p_trials ('00000000-0000-0000-0000-00000000000a', 3,
  '[{"name":"standard","players":2},{"name":"maze","players":2},{"name":"cell","players":2}]');
EXECUTE d_demand ('00000000-0000-0000-0000-00000000000a', 8, 2, 3.0);
