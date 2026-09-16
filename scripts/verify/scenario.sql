-- docs/schema.md draft 3 — the walk, end to end, on the prepared statements.
-- Runs after statements.sql in the same session. Each EXECUTE is its own
-- transaction, as it would be from an Orion task. Match ids are captured with
-- \gset because EXECUTE parameters may not contain subqueries.
\set ON_ERROR_STOP off
\pset footer off

\echo '--- seed: game, users, models, versions, ratings'
INSERT INTO games (id, slug, name, active_engine_digest)
VALUES ('00000000-0000-0000-0000-00000000000a', 'ants', 'Ants', 'sha256:e1');
INSERT INTO seasons (id, game_id, number, engine_digest, submissions_open_at, submissions_close_at)
VALUES ('50000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 1, 'sha256:e1',
        now() - interval '1 hour', now() + interval '1 day');
INSERT INTO users (id, github_id, handle, role) VALUES
  ('00000000-0000-0000-0000-0000000000b1', NULL, 'baseline.random', 'baseline'),
  ('00000000-0000-0000-0000-0000000000a1', 1,    'alice',           'competitor');
-- Two ENTRIES -- one baseline's, one alice's -- and three versions between them. Alice's two
-- versions are the same entry, which is what makes the promotion below a supersede rather than two
-- unrelated models both standing active.
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b1',
   '00000000-0000-0000-0000-00000000000a', 'random'),
  ('e0000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', 'ants brain');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('10000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-0000000000b1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano',
   'sha256:wb1', 'sha256:mb1', '1.8.1'),
  ('20000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano',
   'sha256:wa1', 'sha256:ma1', '1.8.1'),
  ('20000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 2, 'verified', 'nano',
   'sha256:wa2', 'sha256:ma2', '1.8.1');
INSERT INTO ratings (version_id, ladder, mu, sigma) VALUES
  ('10000000-0000-0000-0000-000000000001', 'nano', 25, 8.333),
  ('10000000-0000-0000-0000-000000000001', 'open', 25, 8.333),
  ('20000000-0000-0000-0000-000000000001', 'nano', 30, 4),
  ('20000000-0000-0000-0000-000000000001', 'open', 31, 3.5);

\echo '--- pair: epoch read; trial insert (expect INSERT 0 2 seats); ranked insert (expect 2); second live trial (expect unique violation)'
EXECUTE p_epoch;
EXECUTE p_insert (0, 'ants', 42, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid(), 5);
EXECUTE p_insert (0, 'ants', 43, 'default',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
EXECUTE p_insert (0, 'ants', 44, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid(), 5);
\echo '--- pair: stale epoch (expect 0); a row on another preset (expect 2)'
EXECUTE p_insert (99, 'ants', 45, 'default',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
EXECUTE p_insert (0, 'ants', 46, 'other-map',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
SELECT seed, preset, status, seat_count, ladders, trial_version_id IS NOT NULL AS trial FROM matches ORDER BY seed;
SELECT m.seed, s.seat, s.version_id, s.weights_hash, s.paired_ratings FROM match_seats s JOIN matches m ON m.id = s.match_id ORDER BY m.seed, s.seat;
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
EXECUTE k_start ('30000000-0000-0000-0000-000000000001');
EXECUTE k_renew ('30000000-0000-0000-0000-000000000001', 60);
EXECUTE k_renew ('30000000-0000-0000-0000-000000000009', 60);
\echo '--- kalam: a malformed result naming one seat twice (expect 0, row still running); finish both rows (expect UPDATE 2 seats each); finish again (expect 0)'
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":0,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/x/t1.json');
SELECT seed, status FROM matches WHERE seed = 42;
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/x/t1.json');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/y/t1.json');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/y/t1.json');
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
EXECUTE c_priors (:'m43', 4.1667, 0.0833, 0.10);
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
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat, mu_before, sigma_before, mu_after, sigma_after)
VALUES ('20000000-0000-0000-0000-000000000001', 'nano', 1, :'m43', 0, 30, 4, 29.2, 3.8);
EXECUTE a_chain;
SELECT version_id, ladder, mu, sigma, matches_played FROM ratings ORDER BY version_id, ladder;

\echo '--- count: verdict read (expect alice v2: trials 1, last finished, candidate_seat 0, candidate_rank 1)'
EXECUTE c_verdicts;
EXECUTE c_decide (5, 3);
\echo '--- count: pass under the live fence (expect INSERT 0 2); model_versions_one_active_excl must not fire'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
SELECT v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id
 WHERE e.owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY v.version;
SELECT version_id, ladder, mu, sigma, seed_mu, seed_sigma FROM ratings WHERE version_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder;
SELECT ladder, seq, match_id, mu_before, mu_after, sigma_after FROM rating_events WHERE version_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder, seq;
SELECT key, epoch FROM clocks WHERE key = 'roster';
SELECT seed, status, rated_seq FROM matches WHERE seed = 42;
\echo '--- count: pass again (expect INSERT 0 0)'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
\echo '--- promotion statement 2: withdraw the pending rows naming v1 (expect 1: the other-preset row, successor v2)'
EXECUTE c_withdraw_pred ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002');
SELECT seed, status, withdrawn_reason, successor_version_id FROM matches WHERE seed = 46;
\echo '--- pair with the epoch read before promotion (expect 0: fenced out); with the new epoch (expect 2)'
EXECUTE p_insert (0, 'ants', 47, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
EXECUTE p_insert (1, 'ants', 47, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
\echo '--- withdraw sweep: retire the engine on the live season (expect 1: seed 47 ENGINE_RETIRED); a closed season refuses inserts (expect 0) and the sweep finds nothing queued (expect 0)'
UPDATE games SET active_engine_digest = 'sha256:e2';
UPDATE seasons SET engine_digest = 'sha256:e2';
EXECUTE w_sweep;
SELECT seed, status, withdrawn_reason FROM matches WHERE seed = 47;
UPDATE seasons SET closed_at = now();
EXECUTE p_insert (1, 'ants', 48, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
EXECUTE w_sweep;
UPDATE seasons SET closed_at = NULL;

\echo '--- reject path: v3 verified; its trial fails with a fault on seat 0; verdict read; reject (expect UPDATE 1, epoch 2)'
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 3, 'verified', 'nano',
   'sha256:wa3', 'sha256:ma3', '1.8.1');
EXECUTE p_insert (1, 'ants', 50, 'default',
  '{20000000-0000-0000-0000-000000000003,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000003', gen_random_uuid(), 5);
SELECT id AS m50 FROM matches WHERE seed = 50 \gset
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000003', 60);
EXECUTE k_fail ('30000000-0000-0000-0000-000000000003',
  '[{"weights_hash":"sha256:wa3","reason":"HASH_MISMATCH"}]');
EXECUTE c_verdicts;
EXECUTE c_decide (5, 3);
EXECUTE c_reject ('2026-09-07 10:00:00+00', 2, :'m50', '20000000-0000-0000-0000-000000000003', 'HASH_MISMATCH');
SELECT version, status, reject_reason FROM model_versions WHERE version = 3;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '--- memory refusal: a ranked row claimed then released (expect 1; pending, refusals 1, lapses 0); at the ceiling (expect failed UNLOADABLE)'
EXECUTE p_insert (2, 'ants', 51, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT id AS m51 FROM matches WHERE seed = 51 \gset
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000004', 60);
EXECUTE k_release ('30000000-0000-0000-0000-000000000004', ARRAY[:'m51'::uuid], 5);
SELECT seed, status, refusals, lapses FROM matches WHERE seed = 51;
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000005', 60);
EXECUTE k_release ('30000000-0000-0000-0000-000000000005', ARRAY[:'m51'::uuid], 2);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 51;

\echo '--- soma: a version''s history is one join (expect the rated row 43 for alice v1; the cancelled row 46 is not listed)'
EXECUTE s_history ('20000000-0000-0000-0000-000000000001', 10);

\echo '--- the kalam role: withdraw (expect denied); fake cancelled (expect check violation); fake rated (expect denied); reseat (expect denied); rank without score (expect check violation); read both tables (ok); read model_versions, read or write events (expect denied)'
EXECUTE p_insert (2, 'ants', 52, 'default',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
SET ROLE kalam;
UPDATE matches SET withdrawn_reason = 'x' WHERE seed = 52;
UPDATE matches SET status = 'cancelled', closed_at = now() WHERE seed = 52;
UPDATE matches SET status = 'rated', rated_at = now() WHERE seed = 52;
UPDATE match_seats SET version_id = '20000000-0000-0000-0000-000000000001' WHERE match_id = :'m52' AND seat = 0;
UPDATE match_seats SET rank = 1 WHERE match_id = :'m52' AND seat = 0;
SELECT count(*) AS kalam_reads_matches FROM matches;
SELECT count(*) AS kalam_reads_seats FROM match_seats;
SELECT count(*) FROM model_versions;
SELECT count(*) FROM rating_events;
UPDATE rating_events SET mu_after = 0;
RESET ROLE;

\echo '--- the entry split: two models of one competitor stand together; two versions of ONE model do not'
-- What the change is FOR. Alice takes a second entry and both are active in the same season, which
-- the (owner, game, season) exclusion constraint this replaced would have refused outright.
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', 'second try');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-000000000009', 'e0000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano',
   'sha256:wa9', 'sha256:ma9', '1.8.1');
SELECT e.name, v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id
 WHERE e.owner_id = '00000000-0000-0000-0000-0000000000a1' AND v.status = 'active' ORDER BY e.name;
\echo '    ... and a second active version of one entry in one season is still refused (expect exclusion violation)'
INSERT INTO model_versions (model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version)
VALUES ('e0000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a',
        '50000000-0000-0000-0000-000000000001', 2, 'active', 'nano',
        'sha256:wax', 'sha256:aax', '1.8.1');

\echo '--- the predecessor read is single-row across seasons: the bug the entry scope fixes'
-- A competitor holds an `active` version in EVERY season they ever finished -- a closed season's
-- active version IS its standing. Count's predecessor lookup is a scalar subquery, so scoped by
-- owner alone (as it was before this change) it raises "more than one row" the first time a second
-- season opens, and the count clock dies with the whole ladder behind it.
INSERT INTO seasons (id, game_id, number, engine_digest, submissions_open_at, submissions_close_at, closed_at)
VALUES ('50000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000000a', 2, 'sha256:e0',
        now() - interval '2 days', now() - interval '1 day', now() - interval '1 day');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-00000000000f', 'e0000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000000', 9, 'active', 'nano',
   'sha256:waf', 'sha256:aaf', '1.8.1');
\echo '    owner-scoped (what count used to do) vs entry-and-season-scoped (what it does now):'
SELECT (SELECT count(*) FROM model_versions p JOIN models pe ON pe.id = p.model_id
         WHERE pe.owner_id = '00000000-0000-0000-0000-0000000000a1' AND p.status = 'active')
         AS owner_scoped_rows,
       (SELECT count(*) FROM model_versions p
         WHERE p.model_id = 'e0000000-0000-0000-0000-0000000000a2'
           AND p.season_id = '50000000-0000-0000-0000-000000000001' AND p.status = 'active')
         AS entry_and_season_scoped_rows;

\echo '--- final state'
SELECT seed, preset, status, lapses, refusals, withdrawn_reason, fault_reason, fault_seat, rated_seq FROM matches ORDER BY seed;

\echo '--- the manifest copy: stored as the exact text, accepted when it hashes to manifest_hash (expect INSERT 0 1); one byte changed (expect check violation)'
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version, manifest) VALUES
  ('20000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 4, 'verified', 'nano',
   'sha256:wa4', 'sha256:' || encode(sha256(convert_to('{"in": ["scatter"]}', 'UTF8')), 'hex'),
   '1.8.1', '{"in": ["scatter"]}');
UPDATE model_versions SET manifest = '{"in": ["scatter"] }' WHERE version = 4;

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
  '20000000-0000-0000-0000-000000000004', gen_random_uuid(), 5);
SELECT id AS m60 FROM matches WHERE seed = 60 \gset
EXECUTE k_claim ('sha256:e2', '{}', 1, '30000000-0000-0000-0000-000000000007', 60);
EXECUTE k_start ('30000000-0000-0000-0000-000000000007');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000007', :'m60',
  '[{"seat":0,"rank":1,"score":8,"strikes":0},{"seat":1,"rank":2,"score":2,"strikes":0}]',
  'all_food', 90, now() - interval '2.5 seconds', 'sha256:e2', '1.8.1', 'replays/ants/w/t7.json');
EXECUTE c_pass_reversed ('2026-09-07 10:00:00+00', 2, :'m60', '20000000-0000-0000-0000-000000000004', 25, 8.333, 2.0);
SELECT v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id
 WHERE e.owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY v.version;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '--- jodi/docs/design.md: the trial read now finds nothing (v4 active); the demand view over the final roster (burst 8, steady 2, settled 3.0)'
\echo '    decision 28: the baseline 10000000-...-001 is paced like any version (expect placement, want 6: burst 8 less 2 in flight -- it used to read state baseline, want 0)'
EXECUTE p_trials ('00000000-0000-0000-0000-00000000000a', 3,
  '[{"name":"standard","players":2},{"name":"maze","players":2},{"name":"cell","players":2}]');
EXECUTE d_demand ('00000000-0000-0000-0000-00000000000a', 8, 2, 3.0);

\echo '--- decision 28: pair reads a baseline as it reads anyone. Under a season queue share of 4 the room map names every owner (expect two, alice a1 and the baseline b1, each 2 in flight with room 2), and no want carries a role (expect has_role f)'
SELECT rules AS saved_rules FROM seasons WHERE id = '50000000-0000-0000-0000-000000000001' \gset
UPDATE seasons SET rules = '{"pairing": {"enabled": true, "queue_share_max": 4}}'
 WHERE id = '50000000-0000-0000-0000-000000000001';
EXECUTE p_demand_doc ('00000000-0000-0000-0000-00000000000a', 8, 2, 3.0, 64, 0.2) \gset
SELECT e ->> 'model_id' AS model_id, e ->> 'state' AS state, e ->> 'want' AS want, e::jsonb ? 'role' AS has_role
  FROM json_array_elements((:'body')::json -> 'wants') e ORDER BY 1;
SELECT o ->> 'owner_id' AS owner_id, o ->> 'in_flight' AS in_flight, o ->> 'room' AS room
  FROM json_array_elements((:'body')::json -> 'owners') o ORDER BY 1;
UPDATE seasons SET rules = :'saved_rules'::jsonb WHERE id = '50000000-0000-0000-0000-000000000001';

\echo '===== identity: the handle is a label, and the index protects the namespace the readers use ====='

\echo '--- a baseline handle must live in the reserved namespace (expect check violation)'
INSERT INTO users (github_id, handle, role) VALUES (NULL, 'baseline-legacy', 'baseline');

\echo '--- `Alice` and `alice` are one name (expect duplicate key on users_handle_uniq)'
-- Case-sensitive uniqueness with case-insensitive readers is how two rows came to answer to one
-- login: every reader compares case-insensitively, so two rows both answered to one.
INSERT INTO users (github_id, handle) VALUES (77, 'Alice');

\echo '--- sign-in takes a freed login off the row that provably no longer holds it:'
\echo '    github_id 1 renamed on GitHub and has not signed back in, so its row still says `alice`,'
\echo '    and the account that holds the login now signs in for the first time (expect released.1 / alice)'
UPDATE users SET handle = 'released.' || github_id
 WHERE lower(handle) = lower('alice') AND github_id IS NOT NULL AND github_id <> 99;
INSERT INTO users (github_id, handle, display_name) VALUES (99, 'alice', NULL)
ON CONFLICT (github_id) DO UPDATE SET handle = excluded.handle;
SELECT github_id, handle FROM users WHERE github_id IN (1, 99) ORDER BY github_id;

\echo '--- and the other half: an existing account renaming INTO a login a stale row holds'
\echo '    (expect released.100 / bob -- without the release step both halves are a 500 that never clears)'
INSERT INTO users (github_id, handle) VALUES (100, 'bob'), (101, 'carol');
UPDATE users SET handle = 'released.' || github_id
 WHERE lower(handle) = lower('bob') AND github_id IS NOT NULL AND github_id <> 101;
INSERT INTO users (github_id, handle, display_name) VALUES (101, 'bob', NULL)
ON CONFLICT (github_id) DO UPDATE SET handle = excluded.handle;
SELECT github_id, handle FROM users WHERE github_id IN (100, 101) ORDER BY github_id;

\echo '===== an entry is a name: unique per owner, and deliberately NOT unique across them ====='

\echo '--- one entry per name per owner, case-insensitively (expect INSERT 0 1, then duplicate key on models_owner_game_name_uniq)'
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT id FROM users WHERE github_id = 99), '00000000-0000-0000-0000-00000000000a', 'brain');
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT id FROM users WHERE github_id = 99), '00000000-0000-0000-0000-00000000000a', 'BRAIN');

\echo '--- and TWO COMPETITORS MAY HOLD ONE NAME (expect INSERT 0 1)'
-- The repository was a GLOBAL key, so `alice/brain` could be entered once platform-wide and a
-- second competitor naming the same repository was refused. A name is not an identity and nothing
-- is decided on one, so there is no cross-owner index here and this insert must SUCCEED. Who a
-- competitor is, is users.github_id -- which is sign-in, and the whole of what GitHub does now.
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT id FROM users WHERE github_id = 101), '00000000-0000-0000-0000-00000000000a', 'brain');

\echo '--- the baselines need no carve-out any more (expect INSERT 0 1)'
-- Three of them shared one repository, which was legal only because models_repo_uniq was PARTIAL
-- on owner_github_id. With no repository there is no shared value and no exception to explain.
INSERT INTO users (github_id, handle, role) VALUES (NULL, 'baseline.two', 'baseline');
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT id FROM users WHERE handle = 'baseline.two'),
        '00000000-0000-0000-0000-00000000000a', 'two');

\echo '--- and the season rules document no longer has a `repo` block (expect check violation)'
-- It was the one block whose `enabled` defaulted true, because it was the anti-impersonation rule
-- for a field that limited nothing. Removing the field removed the exception with it.
UPDATE seasons SET rules = '{"repo": {"enabled": true, "allow_orgs": ["acme-lab"]}}'::jsonb
 WHERE number = 1;
