-- The walk, end to end, on the prepared statements.
-- Runs after statements.sql in the same session. Each EXECUTE is its own
-- transaction, as it would be from an Orion task. Match ids are captured with
-- \gset because EXECUTE parameters may not contain subqueries.
\set ON_ERROR_STOP off
\pset footer off

\echo '--- seed: game, users, models, versions, ratings'
INSERT INTO games (id, slug, name, active_engine_digest)
VALUES ('00000000-0000-0000-0000-00000000000a', 'ants', 'Ants', 'sha256:e1');
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at)
VALUES ('50000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 1,
        'Summer 2026', 'summer-2026', 'sha256:e1',
        now() - interval '1 hour', now() + interval '1 day');
INSERT INTO users (id, handle, role) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'baseline.random', 'baseline'),
  ('00000000-0000-0000-0000-0000000000a1', 'alice',           'competitor');
INSERT INTO identities (user_id, provider, subject, login) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'github', '1', 'alice');
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
-- One rated ladder: a version has a single 'open' row (a class is a view of Open).
INSERT INTO ratings (version_id, ladder, mu, sigma) VALUES
  ('10000000-0000-0000-0000-000000000001', 'open', 25, 8.333),
  ('20000000-0000-0000-0000-000000000001', 'open', 31, 3.5);

\echo '--- runners: one admin key, two machines self-registered on it, one revoked (expect mini-1, mini-2)'
-- A runner is not enrolled: it upserts itself on (key_id, label) at token exchange, so these rows
-- are what that leaves behind. mini-2 is allowed ONE row in flight, which is what the ceiling below
-- is measured against. The hash is a stand-in: the key itself never reaches the database.
INSERT INTO users (id, handle, role)
VALUES ('00000000-0000-0000-0000-0000000000ad', 'ops', 'admin');
INSERT INTO identities (user_id, provider, subject, login)
VALUES ('00000000-0000-0000-0000-0000000000ad', 'github', '9', 'ops');
INSERT INTO runner_keys (id, user_id, label, key_hash, key_prefix)
VALUES ('c0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000ad',
        'the fleet', 'sha256:not-a-real-digest', 'tbr_deadbeef');
INSERT INTO runners (id, key_id, label, engine_digest, max_in_flight, match_timeout_ms, seat_concurrency) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'mini-1', 'sha256:e1', 4, 2400000, 2),
  ('c1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'mini-2', 'sha256:e1', 1, 2400000, 1),
  ('c1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'gone',   'sha256:e1', 4, NULL, NULL),
  ('c1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000001', 'short',  'sha256:e1', 4, 60000, 8);
UPDATE runners SET revoked_at = now() WHERE id = 'c1000000-0000-0000-0000-000000000003';
SELECT label, max_in_flight FROM live_runners ORDER BY label;

\echo '--- season maps: three boards uploaded and enabled -- two of two seats, one of four'
-- What soma-admin-maps-add leaves behind, less the engine's judgement, which needs a node. The
-- boards are stand-ins: nothing in the schema reads inside one, which is the point.
INSERT INTO season_maps (id, season_id, map_id, players, rows, cols, digest, board, enabled, added_by) VALUES
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'default',   2, 24, 24, 'sha256:d1', '{"id": "default"}',   true, '00000000-0000-0000-0000-0000000000ad'),
  ('70000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001', 'other-map', 2, 30, 30, 'sha256:d2', '{"id": "other-map"}', true, '00000000-0000-0000-0000-0000000000ad'),
  ('70000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', 'melee',     4, 48, 48, 'sha256:d3', '{"id": "melee"}',     true, '00000000-0000-0000-0000-0000000000ad');
\echo '    the same board twice in a season (expect unique violation)'
INSERT INTO season_maps (season_id, map_id, players, rows, cols, digest, board, added_by)
VALUES ('50000000-0000-0000-0000-000000000001', 'default-again', 2, 24, 24, 'sha256:d1', '{}', '00000000-0000-0000-0000-0000000000ad');
\echo '    a header worth reading (expect a header); "players": "two" (expect null, not a cast error); inside the envelope (t) and one side too long (f)'
SELECT season_map_header('{"id": "tiny-open-2p", "players": 2, "rows": 24, "cols": 24, "water": []}') AS header;
SELECT season_map_header('{"id": "x", "players": "two", "rows": 24, "cols": 24}') IS NULL AS no_header;
SELECT season_map_within('{"players": 2, "rows": 24, "cols": 24}',
                         '{"players": [2, 8], "sides": [24, 124], "cells_max": 14880}') AS inside,
       season_map_within('{"players": 2, "rows": 24, "cols": 125}',
                         '{"players": [2, 8], "sides": [24, 124], "cells_max": 14880}') AS too_long;

\echo '--- pair: epoch read; trial insert (expect INSERT 0 2 seats); ranked insert (expect 2); second live trial (expect unique violation)'
SELECT epoch FROM clocks WHERE key = 'roster';
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 42, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid(), 5);
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 43, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 44, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000002', gen_random_uuid(), 5);
\echo '--- pair: stale epoch (expect 0); a row on another board (expect 2)'
EXECUTE p_insert (99, '50000000-0000-0000-0000-000000000001', 45, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 46, '70000000-0000-0000-0000-000000000002',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}',
  NULL, gen_random_uuid(), 5);
SELECT seed, (SELECT map_id FROM season_maps sm WHERE sm.id = matches.season_map_id) AS map,
       status, seat_count, ladders, trial_version_id IS NOT NULL AS trial FROM matches ORDER BY seed;
\echo '--- pair: a board an admin has disabled takes no new match (expect 0); two seats on a four-seat board take none either -- the insert reads the count off the board (expect 0)'
BEGIN;
UPDATE season_maps SET enabled = false WHERE id = '70000000-0000-0000-0000-000000000002';
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 70, '70000000-0000-0000-0000-000000000002',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
ROLLBACK;
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 71, '70000000-0000-0000-0000-000000000003',
  '{20000000-0000-0000-0000-000000000001,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT m.seed, s.seat, s.version_id, s.weights_hash, s.paired_ratings FROM match_seats s JOIN matches m ON m.id = s.match_id ORDER BY m.seed, s.seat;
SELECT id AS m42 FROM matches WHERE seed = 42 \gset
SELECT id AS m43 FROM matches WHERE seed = 43 \gset
SELECT id AS m46 FROM matches WHERE seed = 46 \gset

\echo '--- kalam: reap (expect 0); nothing in flight yet (expect f); claim ONE row, trials first (expect 1)'
EXECUTE k_reap;
EXECUTE k_in_flight;
\echo '--- a runner whose channel cannot hold a 1000-turn match at 1 s claims nothing (expect 0)'
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000000', 60, 4, 'c1000000-0000-0000-0000-000000000004', 1000, 1000, 5);
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000001', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
\echo '--- one row claimed: something is in flight (expect t)'
EXECUTE k_in_flight;
-- Eight parameters: the read-back also builds the execution contract, so it carries
-- the deploy fallbacks the coalesce lands on when a season declares nothing and the game's
-- manifest has no limits -- which is this fixture, so `turn_ms` here is the 1000 below.
EXECUTE k_row ('30000000-0000-0000-0000-000000000001', 'tb.v', 'replays', 30, 300, 1000, 1000, 5);
\echo '--- a second runner takes the NEXT row rather than queueing behind the first: SKIP LOCKED is the only coordinator there is (expect 1)'
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000002', 60, 4, 'c1000000-0000-0000-0000-000000000002', 1000, 1000, 5);
\echo '--- the in-flight ceiling: mini-2 is allowed one row, so its next claim takes nothing (expect 0)'
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000003', 60, 4, 'c1000000-0000-0000-0000-000000000002', 1000, 1000, 5);
\echo '--- a REVOKED runner claims nothing, however live its token: the check is a JOIN inside the statement (expect 0)'
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000004', 60, 4, 'c1000000-0000-0000-0000-000000000003', 1000, 1000, 5);
\echo '--- mini-1 takes the row that is left, and every claim named the machine that took it'
EXECUTE k_claim ('sha256:e1', '30000000-0000-0000-0000-000000000005', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
SELECT m.seed, r.label AS played_by FROM matches m JOIN runners r ON r.id = m.played_by ORDER BY m.seed;
\echo '--- kalam: start on ANOTHER runner''s claim (expect 0); start it properly (expect 1 each); renew (expect 1); renew on a foreign token (expect 0)'
EXECUTE k_start ('30000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002', :'m42');
EXECUTE k_start ('30000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', :'m42');
EXECUTE k_start ('30000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000002', :'m43');
EXECUTE k_renew ('30000000-0000-0000-0000-000000000001', 60, 'c1000000-0000-0000-0000-000000000001', :'m42');
EXECUTE k_renew ('30000000-0000-0000-0000-000000000009', 60, 'c1000000-0000-0000-0000-000000000001', :'m42');
\echo '--- kalam: a malformed result naming one seat twice (expect 0, row still running); finish both rows (expect UPDATE 2 seats each); finish again (expect 0)'
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":0,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/x/t1.json', 'c1000000-0000-0000-0000-000000000001', NULL);
SELECT seed, status FROM matches WHERE seed = 42;
EXECUTE k_finish ('30000000-0000-0000-0000-000000000001', :'m42',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/x/t1.json', 'c1000000-0000-0000-0000-000000000001',
  '{"ants": [[3, 4, 0]], "food": [[5, 5]], "scores": [10, 3]}');
-- m43 sends a frame OVER 64 KB: the match still finishes (UPDATE 2) and no frame is stored.
EXECUTE k_finish ('30000000-0000-0000-0000-000000000002', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/y/t1.json', 'c1000000-0000-0000-0000-000000000002',
  json_build_object('pad', repeat('x', 70000))::jsonb);
EXECUTE k_finish ('30000000-0000-0000-0000-000000000002', :'m43',
  '[{"seat":0,"rank":2,"score":3,"strikes":1},{"seat":1,"rank":1,"score":10,"strikes":0}]',
  'all_food', 200, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/ants/y/t1.json', 'c1000000-0000-0000-0000-000000000002', NULL);
-- m46 has to BE running and BE this runner's before any of the four below tests what it means to
-- test. Without this they all answer 0 on `status = 'running'` and the gates look like they work
-- while doing nothing -- which is how a negative test passes for the wrong reason.
UPDATE matches SET status = 'claimed', claim_token = '30000000-0000-0000-0000-000000000003',
       lease_expires_at = now() + interval '60 seconds',
       played_by = 'c1000000-0000-0000-0000-000000000002'
 WHERE id = :'m46';
EXECUTE k_start ('30000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000002', :'m46');

\echo '--- the misconfiguration gates: a result that cannot have come from this match (expect 0 each,'
\echo '    and the row stays running for the reap rather than taking a result no fold can trust)'
-- A DIFFERENT ENGINE than the row required. engine_digest_played was recorded and never compared
-- until now, so a replica pinned to the wrong digest wrote results nobody could use, silently.
EXECUTE k_finish ('30000000-0000-0000-0000-000000000003', :'m46',
  '[{"seat":0,"rank":1,"score":10,"strikes":0},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:SOMETHING-ELSE', '1.8.1', 'replays/x.json',
  'c1000000-0000-0000-0000-000000000002', NULL);
-- STRIKES ABOVE THE CEILING THE ROW WAS QUEUED UNDER. Pair pins strike_ceiling on the row
-- so a trial is judged by the rule it was played under; this is that rule read back.
EXECUTE k_finish ('30000000-0000-0000-0000-000000000003', :'m46',
  '[{"seat":0,"rank":1,"score":10,"strikes":99},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/x.json',
  'c1000000-0000-0000-0000-000000000002', NULL);
-- A RANK OUTSIDE THE BOUND. Not a permutation check: Ants ranks from 1 and allows ties, so {1,1}
-- is a draw and the commonest two-seat result. What is bounded is 1 <= rank <= 2*seat_count, the
-- ceiling being the forfeit rule (engine_rank + seat_count).
EXECUTE k_finish ('30000000-0000-0000-0000-000000000003', :'m46',
  '[{"seat":0,"rank":0,"score":10,"strikes":0},{"seat":1,"rank":2,"score":3,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/x.json',
  'c1000000-0000-0000-0000-000000000002', NULL);
\echo '--- and a DRAW, which is a real result and must pass (expect UPDATE 2); its frame is not an object, so none is stored'
EXECUTE k_finish ('30000000-0000-0000-0000-000000000003', :'m46',
  '[{"seat":0,"rank":1,"score":7,"strikes":0},{"seat":1,"rank":1,"score":7,"strikes":0}]',
  'all_food', 120, now() - interval '4 seconds', 'sha256:e1', '1.8.1', 'replays/x.json',
  'c1000000-0000-0000-0000-000000000002', '[1, 2, 3]');
\echo '--- the last frame: m42 sent one and it is stored at its turn; m43 sent one over 64 KB and m46 one that is not an object, and neither is (expect 42 | 120 | t, and nothing else)'
SELECT m.seed, f.turn, f.frame ? 'ants' AS opaque_as_sent
  FROM match_frames f JOIN matches m ON m.id = f.match_id ORDER BY m.seed;

\echo '--- and the read-back that tells a DUPLICATE DELIVERY from a stale token: finished and still mine is a success, not a 409'
SELECT seed, status AS state, (claim_token = '30000000-0000-0000-0000-000000000002') AS mine FROM matches WHERE seed = 43;
SELECT m.seed, s.seat, s.rank, s.score, s.strikes FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.seed IN (42, 43) ORDER BY m.seed, s.seat;
\echo '--- kalam: the other replica lapses; reap after expiry (expect 1: back to pending, lapses 1, token cleared)'
UPDATE matches SET lease_expires_at = now() - interval '1 second' WHERE claim_token = '30000000-0000-0000-0000-000000000005';
EXECUTE k_reap;
SELECT seed, status, lapses, claim_token IS NULL AS token_cleared,
       played_by IS NOT NULL AS still_attributed FROM matches WHERE seed = 46;

\echo '--- count: fence claim attempt 1 (expect 1); an older occurrence (expect 0); a retry, attempt 2 (expect 1)'
EXECUTE c_fence ('2026-09-07 10:00:00+00', 1);
EXECUTE c_fence ('2026-09-07 09:59:00+00', 1);
EXECUTE c_fence ('2026-09-07 10:00:00+00', 2);
\echo '--- count: batch document (expect n 3: two folds, then the verdict on alice v2 -- decision pass, trials 1); priors for the ranked row'
EXECUTE c_batch_doc (10, 3);
EXECUTE c_priors (:'m43', 4.1667, 0.0833, 0.10);
\echo '--- count: fold under the stale fence (expect 0, row still finished); under the live fence (expect 2 -- one posterior per seat on the one Open ladder); again (expect 0); on the trial row (expect 0, row untouched)'
EXECUTE c_fold ('2026-09-07 10:00:00+00', 1, :'m43',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"open","mu":30.3,"sigma":3.4},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":27.4,"sigma":6.2}]');
SELECT seed, status FROM matches WHERE seed = 43;
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m43',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000001","ladder":"open","mu":30.3,"sigma":3.4},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":27.4,"sigma":6.2}]');
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m43', '[]');
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m42', '[]');
\echo '--- count: why a fold moved nothing -- under the stale fence (expect mine f); under the live fence on the rated row (expect mine t, unfoldable f); on a row still finished (expect mine t, unfoldable t)'
EXECUTE c_held_why ('2026-09-07 10:00:00+00', 1, :'m43');
EXECUTE c_held_why ('2026-09-07 10:00:00+00', 2, :'m43');
EXECUTE c_held_why ('2026-09-07 10:00:00+00', 2, :'m42');
SELECT seed, status, rated_seq FROM matches WHERE seed IN (42, 43) ORDER BY seed;
EXECUTE s_match_change (:'m43');
\echo '--- rating events: a duplicate seq is refused by the chain key (expect unique violation); the chain audit finds no break (expect 0 rows)'
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat, mu_before, sigma_before, mu_after, sigma_after)
VALUES ('20000000-0000-0000-0000-000000000001', 'open', 1, :'m43', 0, 31, 3.5, 30.3, 3.4);
EXECUTE a_chain;
SELECT version_id, ladder, mu, sigma, matches_played FROM ratings ORDER BY version_id, ladder;

\echo '--- count: batch document after the fold (expect n 2: the fold still waiting, then the verdict on alice v2 -- decision pass, reason null, trials 1)'
EXECUTE c_batch_doc (10, 3);
\echo '--- count: pass under the live fence (expect INSERT 0 1 -- one Open rating_events seed); model_versions_one_active_excl must not fire'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
SELECT v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id
 WHERE e.owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY v.version;
SELECT version_id, ladder, mu, sigma, seed_mu, seed_sigma FROM ratings WHERE version_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder;
SELECT ladder, seq, match_id, mu_before, mu_after, sigma_after FROM rating_events WHERE version_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder, seq;
SELECT key, epoch FROM clocks WHERE key = 'roster';
SELECT seed, status, rated_seq FROM matches WHERE seed = 42;
\echo '--- count: pass again (expect INSERT 0 0)'
EXECUTE c_pass ('2026-09-07 10:00:00+00', 2, :'m42', '20000000-0000-0000-0000-000000000002', 25, 8.333, 2.0);
\echo '--- the sort keys: the fold wrote m43''s margin (10 - 3) and its upset -- alice v1''s conservative open rating before the fold, 20.50, over the winning baseline''s 0.00, so positive: an upset. The pass wrote the trial''s margin and no upset: a trial feeds no ladder (expect 42 7 null, 43 7 20.50)'
SELECT seed, margin, round(upset::numeric, 2) AS upset FROM matches WHERE seed IN (42, 43) ORDER BY seed;
\echo '    read again long after, through rating_events.*_before, the upset is the one the fold stored; a disqualified loser is no upset at all (expect 20.50, then t), rolled back'
SELECT round(k.upset::numeric, 2) AS upset_from_events FROM match_sort_keys(:'m43') k;
BEGIN;
UPDATE match_seats SET strikes = 5 WHERE match_id = :'m43' AND seat = 0;
SELECT k.upset IS NULL AS dq_left_out FROM match_sort_keys(:'m43') k;
ROLLBACK;
\echo '--- the counts the fold moved, which the maps page and the season read: one rated ordinary match on its board and in the season, the board''s latest; the passed trial is listed and counted nowhere (expect 1 | 1 | t)'
SELECT sm.matches, se.matches_played, sm.latest_match_id = :'m43' AS latest
  FROM matches m JOIN season_maps sm ON sm.id = m.season_map_id JOIN seasons se ON se.id = m.season_id
 WHERE m.seed = 43;
\echo '--- the last frame of a public match: m42''s trial went public with its frame, m43 sent none (expect 120 t, then null f)'
EXECUTE x_frame (:'m42', NULL, NULL) \gset f42_
SELECT (:'f42_body'::json)->>'turn' AS turn, :'f42_has_frame' AS has_frame;
EXECUTE x_frame (:'m43', NULL, NULL) \gset f43_
SELECT (:'f43_body'::json)->>'turn' AS turn, :'f43_has_frame' AS has_frame;
\echo '--- watch events: a visit, an opened public match, and a random id that writes nothing (expect INSERT 0 1, INSERT 0 1, INSERT 0 0; then opened tv 1, visit 1), rolled back'
BEGIN;
EXECUTE x_events ('visit', NULL, NULL);
EXECUTE x_events ('opened', :'m43', 'tv');
EXECUTE x_events ('opened', '30000000-0000-0000-0000-999999999999', 'tv');
SELECT event, via, sum(n) FROM watch_events GROUP BY 1, 2 ORDER BY 1, 2;
ROLLBACK;
\echo '--- a live season''s podium is empty; an unknown season answers no row (expect {}, then 0 rows)'
EXECUTE x_podium ('ants', 'summer-2026', NULL, NULL) \gset po_
SELECT (:'po_body'::json)->'ladders' AS ladders;
EXECUTE x_podium ('ants', 'no-such-season', NULL, NULL);
\echo '--- who may see a trial: alice v2''s, now that v2 is active (expect t); an ordinary match (expect t)'
SELECT m.seed, match_public(m) FROM matches m WHERE m.seed IN (42, 43) ORDER BY m.seed;
\echo '--- a version is public once it is: v2 active answers, v1 superseded answers (expect 2 rows, versions 1 and 2)'
EXECUTE v_public ('20000000-0000-0000-0000-000000000002', 2.0, NULL, NULL);
EXECUTE v_public ('20000000-0000-0000-0000-000000000001', 2.0, NULL, NULL);
\echo '--- promotion statement 2: withdraw the pending rows naming v1 (expect 1: the other-board row, successor v2)'
EXECUTE c_withdraw_pred ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002');
SELECT seed, status, withdrawn_reason, successor_version_id FROM matches WHERE seed = 46;
\echo '--- pair with the epoch read before promotion (expect 0: fenced out); with the new epoch (expect 2)'
EXECUTE p_insert (0, '50000000-0000-0000-0000-000000000001', 47, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
EXECUTE p_insert (1, '50000000-0000-0000-0000-000000000001', 47, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
\echo '--- withdraw sweep: retire the engine on the live season (expect 1: seed 47 ENGINE_RETIRED); a closed season refuses inserts (expect 0) and the sweep finds nothing queued (expect 0)'
UPDATE games SET active_engine_digest = 'sha256:e2';
UPDATE seasons SET engine_digest = 'sha256:e2';
EXECUTE w_sweep;
SELECT seed, status, withdrawn_reason FROM matches WHERE seed = 47;
UPDATE seasons SET closed_at = now();
EXECUTE p_insert (1, '50000000-0000-0000-0000-000000000001', 48, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
EXECUTE w_sweep;
UPDATE seasons SET closed_at = NULL;

\echo '--- reject path: v3 verified; its only trial fails LEASE_LAPSED under a one-trial ceiling; verdict read; reject (expect UPDATE 1, epoch 2)'
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 3, 'verified', 'nano',
   'sha256:wa3', 'sha256:ma3', '1.8.1');
EXECUTE p_insert (1, '50000000-0000-0000-0000-000000000001', 50, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000003,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000003', gen_random_uuid(), 5);
SELECT id AS m50 FROM matches WHERE seed = 50 \gset
-- No shipped statement fails a row directly: a match fails by the reap's third lapse or the
-- release ceiling, and a model's own failures are strikes, reported through the finish. So this
-- UPDATE is SETUP, not a statement under test -- it leaves the row as the reap's third lapse does.
UPDATE matches SET status = 'failed', fault_reason = 'LEASE_LAPSED', lapses = 3,
       claim_token = NULL, lease_expires_at = NULL, closed_at = now()
 WHERE id = :'m50';
\echo '--- count: batch document with trials_max 1 (expect n 2: the fold still waiting, then the verdict on v3 -- decision reject, reason UNPLAYABLE)'
EXECUTE c_batch_doc (10, 1);
EXECUTE c_reject ('2026-09-07 10:00:00+00', 2, :'m50', '20000000-0000-0000-0000-000000000003', 'UNPLAYABLE');
SELECT version, status, reject_reason FROM model_versions WHERE version = 3;
\echo '--- a rejected candidate stays private: its version answers nothing publicly, and its trial is no public match (expect 0 rows, then 50 f)'
EXECUTE v_public ('20000000-0000-0000-0000-000000000003', 2.0, NULL, NULL);
SELECT m.seed, match_public(m) FROM matches m WHERE m.seed = 50;
\echo '    ... but its owner watches it: alice''s session reads the trial whole, a session of someone with no seat reads nothing, and a missing session no row at all (expect alice''s session and the failed trial''s body, then the admin''s session and a null body, then 0 rows), rolled back'
BEGIN;
INSERT INTO sessions (sid, user_id, expires_at) VALUES
  ('5e000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', now() + interval '1 day'),
  ('5e000000-0000-0000-0000-0000000000ad', '00000000-0000-0000-0000-0000000000ad', now() + interval '1 day');
SELECT id AS m50_id FROM matches WHERE seed = 50 \gset
EXECUTE u_match ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', :'m50_id');
EXECUTE u_match ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', :'m50_id');
EXECUTE u_match ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000ff', :'m50_id');
ROLLBACK;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '===== notifications: what the clocks tell a competitor ====='
\echo '--- the result of rated row 43, where alice lost with a strike: notable under the default level (expect INSERT 0 1 -- alice only, the baseline is told nothing); again (expect INSERT 0 0); the trial row 42 (expect INSERT 0 0)'
EXECUTE n_results (:'m43');
EXECUTE n_results (:'m43');
EXECUTE n_results (:'m42');
\echo '--- the ranks of row 43: alice stayed first on Open and in her class, so nothing moved (expect INSERT 0 0)'
EXECUTE n_ranks (:'m43', 5.0);
\echo '--- a fold that FLIPS the open ladder, rolled back: alice v2 from 2nd to 1st. Unsettled (settled_sigma 1.0) says nothing (expect INSERT 0 0); settled, alice is told on Open and in her class and the baseline is not (expect INSERT 0 2); again (expect INSERT 0 0)'
BEGIN;
INSERT INTO matches (id, game_id, season_id, status, engine_digest, seed, season_map_id, seat_count, ladders,
                     claim_token, replay_key, engine_digest_played, orion_version, played_at, rated_at, rated_seq)
VALUES ('60000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a',
        '50000000-0000-0000-0000-000000000001', 'rated', 'sha256:e2', 900, '70000000-0000-0000-0000-000000000001', 2, '{open}',
        gen_random_uuid(), 'replays/flip', 'sha256:e2', '1.8.1', now(), now(), nextval('rating_seq'));
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, rank, score, strikes) VALUES
  ('60000000-0000-0000-0000-0000000000f1', 0, '20000000-0000-0000-0000-000000000002', 'sha256:wa2', 'sha256:ma2', 1, 9, 0),
  ('60000000-0000-0000-0000-0000000000f1', 1, '10000000-0000-0000-0000-000000000001', 'sha256:wb1', 'sha256:mb1', 2, 1, 0);
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat, mu_before, sigma_before, mu_after, sigma_after) VALUES
  ('20000000-0000-0000-0000-000000000002', 'open', 900, '60000000-0000-0000-0000-0000000000f1', 0, 20, 2, 40, 2),
  ('10000000-0000-0000-0000-000000000001', 'open', 900, '60000000-0000-0000-0000-0000000000f1', 1, 35, 2, 30, 2);
UPDATE ratings SET mu = 40, sigma = 2 WHERE version_id = '20000000-0000-0000-0000-000000000002' AND ladder = 'open';
UPDATE ratings SET mu = 30, sigma = 2 WHERE version_id = '10000000-0000-0000-0000-000000000001' AND ladder = 'open';
EXECUTE n_ranks ('60000000-0000-0000-0000-0000000000f1', 1.0);
EXECUTE n_ranks ('60000000-0000-0000-0000-0000000000f1', 3.0);
EXECUTE n_ranks ('60000000-0000-0000-0000-0000000000f1', 3.0);
SELECT tone, subject, description, link, data FROM notifications WHERE category = 'ratings';
ROLLBACK;
\echo '--- the verdicts: alice v2 passed its trial (expect INSERT 0 1), twice (expect INSERT 0 0); v3 failed it (expect INSERT 0 1); v1 is superseded, which nobody is told (expect INSERT 0 0)'
EXECUTE n_version ('20000000-0000-0000-0000-000000000002');
EXECUTE n_version ('20000000-0000-0000-0000-000000000002');
EXECUTE n_version ('20000000-0000-0000-0000-000000000003');
EXECUTE n_version ('20000000-0000-0000-0000-000000000001');
SELECT category, kind, tone, subject, description, link, actor, data, dedupe_key, read_at IS NULL AS unread
  FROM notifications ORDER BY dedupe_key;
\echo '--- the settings decide inside the insert: matches off, and a locked category (expect f, t, f, f, then check violations on a locked category turned off and a level where none exists)'
INSERT INTO notification_settings (user_id, category, app, push, level)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'matches', true, false, 'off');
SELECT notification_wanted('00000000-0000-0000-0000-0000000000a1', 'matches', true)  AS matches_off,
       notification_wanted('00000000-0000-0000-0000-0000000000a1', 'submissions')    AS submissions,
       notification_wanted('00000000-0000-0000-0000-0000000000a1', 'admin')          AS admin_for_a_competitor,
       notification_wanted('00000000-0000-0000-0000-0000000000b1', 'submissions')    AS a_baseline;
INSERT INTO notification_settings (user_id, category, app, push, level)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'submissions', false, false, NULL);
INSERT INTO notification_settings (user_id, category, app, push, level)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'ratings', true, false, 'all');
DELETE FROM notification_settings;
\echo '--- the settings object: six categories for a competitor, seven for an admin, none for a baseline (expect 6, 7, 0)'
SELECT json_array_length(notification_settings_json('00000000-0000-0000-0000-0000000000a1')) AS competitor,
       json_array_length(notification_settings_json('00000000-0000-0000-0000-0000000000ad')) AS admin,
       json_array_length(notification_settings_json('00000000-0000-0000-0000-0000000000b1')) AS baseline;
\echo '--- a link is an application path (expect check violation on //host)'
INSERT INTO notifications (user_id, category, kind, subject, link, dedupe_key)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'account', 'account', 'x', '//evil.example/x', 'harness:link');
\echo '--- the expiry: a row the admit run stamped with its token is told once (expect INSERT 0 1, then INSERT 0 0), inside a rolled-back transaction'
BEGIN;
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, reject_reason, admit_token)
VALUES ('20000000-0000-0000-0000-0000000000e1', 'e0000000-0000-0000-0000-0000000000a1',
        '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 90, 'rejected',
        'TIMED_OUT', '40000000-0000-0000-0000-0000000000e1');
EXECUTE n_expired ('40000000-0000-0000-0000-0000000000e1');
EXECUTE n_expired ('40000000-0000-0000-0000-0000000000e1');
SELECT subject, tone, data ->> 'reason_code' AS reason_code FROM notifications WHERE version_id = '20000000-0000-0000-0000-0000000000e1';
ROLLBACK;
\echo '--- the close: everyone who entered is told once, with where they finished on open, ranked the podium''s way -- one place per owner and no baselines, so 1st of 1; the baseline is not told (expect INSERT 0 1, then INSERT 0 0), rolled back'
BEGIN;
UPDATE seasons SET closed_at = now() WHERE id = '50000000-0000-0000-0000-000000000001';
EXECUTE n_season ('00000000-0000-0000-0000-00000000000a');
EXECUTE n_season ('00000000-0000-0000-0000-00000000000a');
SELECT subject, description, link, season, data FROM notifications WHERE category = 'season';
ROLLBACK;
\echo '--- the close freezes the podium: one place per owner -- alice''s better entry stands for her and her other is not a second place -- and the baseline is skipped; then a medal per place, once (expect nano and open each alice then carol, INSERT 0 4, INSERT 0 0, four medal rows), rolled back'
BEGIN;
INSERT INTO users (id, handle) VALUES ('00000000-0000-0000-0000-0000000000c1', 'carol');
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'ants lord'),
  ('e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 'colony');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-0000000000a2', 'e0000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano', 'sha256:wl1', 'sha256:ml1', '1.8.1'),
  ('20000000-0000-0000-0000-0000000000c1', 'e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano', 'sha256:wc1', 'sha256:mc1', '1.8.1');
INSERT INTO ratings (version_id, ladder, mu, sigma) VALUES
  ('20000000-0000-0000-0000-0000000000a2', 'open', 40, 2),
  ('20000000-0000-0000-0000-0000000000c1', 'open', 28, 2);
UPDATE seasons SET close_requested_at = now() WHERE id = '50000000-0000-0000-0000-000000000001';
EXECUTE w_close ('00000000-0000-0000-0000-00000000000a', 2.0, 3);
SELECT sp.ladder, sp.place, u.handle, e.name, sp.rating FROM season_podium sp
  JOIN users u ON u.id = sp.owner_id JOIN model_versions v ON v.id = sp.version_id JOIN models e ON e.id = v.model_id
 ORDER BY sp.ladder, sp.place;
EXECUTE n_medal ('00000000-0000-0000-0000-00000000000a');
EXECUTE n_medal ('00000000-0000-0000-0000-00000000000a');
SELECT u.handle, n.category, n.subject, n.data, n.dedupe_key FROM notifications n JOIN users u ON u.id = n.user_id
 WHERE n.kind = 'medal' ORDER BY u.handle, n.subject;
ROLLBACK;
\echo '--- the word list: a listed word holds whole and case-blind, a phrase too; a link holds only where links count (expect scam, dm me, link, null, null)'
BEGIN;
INSERT INTO comment_words (word, added_by) VALUES ('scam', '00000000-0000-0000-0000-0000000000ad'), ('dm me', '00000000-0000-0000-0000-0000000000ad');
SELECT text_hold_tag('this ladder is a SCAM', true) AS word, text_hold_tag('please DM me later', false) AS phrase,
       text_hold_tag('see https://example.io/x', true) AS link, text_hold_tag('see https://example.io/x', false) AS link_allowed,
       text_hold_tag('scampi for dinner', true) AS whole_words_only;
\echo '    and a word is one line of letters, digits and single separators (expect check violation)'
INSERT INTO comment_words (word, added_by) VALUES ('sc.m', '00000000-0000-0000-0000-0000000000ad');
ROLLBACK;
\echo '--- the field at an instant: a version stands from its seq-0 row on Open until a later version of its entry has one (expect on 1 Feb x v1 18.00 #1 and colony 10.00 #2; on 1 Mar x v2 22.00 #1 and colony 10.00 #2); the hour''s snapshot, one Open row per season, written once (expect INSERT 0 1, INSERT 0 1, then INSERT 0 0); the series reads it for each edge but the last (expect 3 edges; x v1 then null, x v2 null then a rating)'
BEGIN;
INSERT INTO users (id, handle) VALUES ('00000000-0000-0000-0000-0000000000c1', 'carol');
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'x'),
  ('e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 'colony');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-0000000000a3', 'e0000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'superseded', 'nano', 'sha256:wx1', 'sha256:mx1', '1.8.1'),
  ('20000000-0000-0000-0000-0000000000a4', 'e0000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 2, 'active', 'nano', 'sha256:wx2', 'sha256:mx2', '1.8.1'),
  ('20000000-0000-0000-0000-0000000000c1', 'e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano', 'sha256:wc1', 'sha256:mc1', '1.8.1');
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after, created_at) VALUES
  ('20000000-0000-0000-0000-0000000000a3', 'open', 0, 30, 4, '2026-01-01'),
  ('20000000-0000-0000-0000-0000000000c1', 'open', 0, 22, 4, '2026-01-01'),
  ('20000000-0000-0000-0000-0000000000a4', 'open', 0, 34, 4, '2026-02-15');
SELECT '1 Feb' AS at, e.name, v.version, round(l.conservative::numeric, 2) AS rating, l.rank
  FROM ladder_at('50000000-0000-0000-0000-000000000001', 'open', '2026-02-01') l
  JOIN model_versions v ON v.id = l.version_id JOIN models e ON e.id = v.model_id ORDER BY l.rank;
SELECT '1 Mar' AS at, e.name, v.version, round(l.conservative::numeric, 2) AS rating, l.rank
  FROM ladder_at('50000000-0000-0000-0000-000000000001', 'open', '2026-03-01') l
  JOIN model_versions v ON v.id = l.version_id JOIN models e ON e.id = v.model_id ORDER BY l.rank;
UPDATE seasons SET submissions_open_at = '2026-01-01' WHERE id = '50000000-0000-0000-0000-000000000001';
SELECT date_trunc('hour', timestamptz '2026-01-15') AS h0,
       date_trunc('hour', timestamptz '2026-01-15' + (now() - timestamptz '2026-01-15') / 2) AS h1 \gset
EXECUTE w_snapshot ('00000000-0000-0000-0000-00000000000a', :'h0');
EXECUTE w_snapshot ('00000000-0000-0000-0000-00000000000a', :'h1');
EXECUTE w_snapshot ('00000000-0000-0000-0000-00000000000a', :'h1');
SELECT json_array_length(r -> 'edges') AS edges, x ->> 'model' AS model, x ->> 'version' AS version,
       (x -> 'ratings' ->> 0) AS first_edge, (x -> 'ratings' ->> 1) AS second_edge
  FROM (SELECT rating_series('50000000-0000-0000-0000-000000000001', 'open', '2026-01-15', 3) AS r) s,
       json_array_elements(s.r -> 'versions') x
 WHERE x ->> 'model' IN ('x', 'colony') ORDER BY 2, 3;
ROLLBACK;

\echo '--- refusal: a ranked row claimed then released (expect 1; pending, refusals 1, lapses 0)'
EXECUTE p_insert (2, '50000000-0000-0000-0000-000000000001', 51, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT id AS m51 FROM matches WHERE seed = 51 \gset
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000006', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-000000000006', true, 5, 'c1000000-0000-0000-0000-000000000001', :'m51', 0);
SELECT seed, status, refusals, lapses FROM matches WHERE seed = 51;
\echo '    ... the ceiling spent INSIDE the grace does not fail it: the row was paired a moment ago (expect 1; pending, refusals 2, no fault)'
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000007', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-000000000007', true, 2, 'c1000000-0000-0000-0000-000000000001', :'m51', 3600);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 51;
\echo '    ... past the grace, a season ceiling above the fallback still holds it: the release reads the value the claim sent (expect 1; pending, refusals 3), rolled back'
BEGIN;
UPDATE seasons SET rules = rules || '{"execution": {"enabled": true, "refusal_ceiling": 10}}'
 WHERE id = '50000000-0000-0000-0000-000000000001';
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-00000000000b', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-00000000000b', true, 2, 'c1000000-0000-0000-0000-000000000001', :'m51', 0);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 51;
ROLLBACK;
\echo '    ... past the grace at the ceiling (expect 1; failed, refusals 3, MODEL_UNAVAILABLE)'
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-00000000000c', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-00000000000c', true, 2, 'c1000000-0000-0000-0000-000000000001', :'m51', 0);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 51;

\echo '--- THE COLD FLEET: a row paired an hour ago, never refused, meets runners with an empty roster.'
\echo '    The grace is the FLEET''s allowance, not the row''s age, so the first refusal starts it and'
\echo '    cannot be the one that fails the row -- however old the row is (expect pending, refusals 1,'
\echo '    no fault, the window opened now). Anchored to created_at this failed on the first refusal,'
\echo '    which is what replacing a fleet with work queued looks like: the release runbook''s step 10.'
BEGIN;
EXECUTE p_insert (2, '50000000-0000-0000-0000-000000000001', 71, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT id AS m71 FROM matches WHERE seed = 71 \gset
UPDATE matches SET created_at = now() - interval '1 hour' WHERE seed = 71;
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000071', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-000000000071', true, 1, 'c1000000-0000-0000-0000-000000000001', :'m71', 120);
SELECT seed, status, refusals, fault_reason, first_refused_at > now() - interval '1 minute' AS window_opened_now
  FROM matches WHERE seed = 71;
\echo '    ... and the fleet that never catches up still loses it, a grace after the refusals began,'
\echo '        at the ceiling and not before (expect pending at the ceiling inside the window, then failed)'
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000072', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-000000000072', true, 2, 'c1000000-0000-0000-0000-000000000001', :'m71', 120);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 71;
UPDATE matches SET first_refused_at = now() - interval '5 minutes' WHERE seed = 71;
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000073', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-000000000073', true, 3, 'c1000000-0000-0000-0000-000000000001', :'m71', 120);
SELECT seed, status, refusals, fault_reason FROM matches WHERE seed = 71;
ROLLBACK;

\echo '--- soma: a version''s history is one join (expect the rated row 43 for alice v1; the cancelled row 46 is not listed)'
EXECUTE s_history ('20000000-0000-0000-0000-000000000001', 10);

\echo '--- the runner_gate role: withdraw (expect denied); fake cancelled (expect check violation); fake rated (expect denied); reseat (expect denied); rank without score (expect check violation); read both tables (ok); count model_versions (ok: its roster columns are granted); read or write events (expect denied)'
EXECUTE p_insert (2, '50000000-0000-0000-0000-000000000001', 52, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000002,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
SET ROLE runner_gate;
UPDATE matches SET withdrawn_reason = 'x' WHERE seed = 52;
UPDATE matches SET status = 'cancelled', closed_at = now() WHERE seed = 52;
UPDATE matches SET status = 'rated', rated_at = now() WHERE seed = 52;
UPDATE match_seats SET version_id = '20000000-0000-0000-0000-000000000001' WHERE match_id = :'m52' AND seat = 0;
UPDATE match_seats SET rank = 1 WHERE match_id = :'m52' AND seat = 0;
SELECT count(*) AS gate_reads_matches FROM matches;
SELECT count(*) AS gate_reads_seats FROM match_seats;
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
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, closed_at)
VALUES ('50000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000000a', 2,
        'FireAnts 2026', 'fireants-2026', 'sha256:e0',
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
SELECT seed, (SELECT map_id FROM season_maps sm WHERE sm.id = matches.season_map_id) AS map,
       status, lapses, refusals, withdrawn_reason, fault_reason, rated_seq FROM matches ORDER BY seed;

\echo '--- the manifest copy: stored as the exact text, accepted when it hashes to manifest_hash (expect INSERT 0 1); one byte changed (expect check violation)'
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status,
                            weight_class, weights_hash, manifest_hash, orion_version, manifest) VALUES
  ('20000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 4, 'verified', 'nano',
   'sha256:wa4', 'sha256:' || encode(sha256(convert_to('{"in": ["scatter"]}', 'UTF8')), 'hex'),
   '1.8.1', '{"in": ["scatter"]}');
UPDATE model_versions SET manifest = '{"in": ["scatter"] }' WHERE version = 4;

\echo '--- the trial read pairs v4 (verified, no live trial, 0 trials) with the nano baseline on the season''s first enabled board, `default` (expect n 1, 2 seats, map 70000000-...-001)'
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
\echo '--- the board decides the seat count. Only one baseline exists here, so with the two-seat boards disabled the four-seat one is left unpaired rather than seated short (expect n 0)'
BEGIN;
UPDATE season_maps SET enabled = false WHERE players = 2;
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
\echo '    ... and a season with no board enabled offers nothing at all (expect n 0)'
UPDATE season_maps SET enabled = false;
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
ROLLBACK;
\echo '--- a refused trial is not the candidate''s attempt: v4''s trial fails MODEL_UNAVAILABLE (expect failed), yet v4 is offered again on the same first board (expect n 1, map 70000000-...-001), and count reads the refusal as a repair with 0 trials spent, not UNPLAYABLE (expect decision repair, trials 0), rolled back'
BEGIN;
EXECUTE p_insert (2, '50000000-0000-0000-0000-000000000001', 59, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000004,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000004', gen_random_uuid(), 5);
SELECT id AS m59 FROM matches WHERE seed = 59 \gset
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-00000000000d', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_release ('30000000-0000-0000-0000-00000000000d', true, 1, 'c1000000-0000-0000-0000-000000000001', :'m59', 0);
SELECT seed, status, fault_reason FROM matches WHERE seed = 59;
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
EXECUTE c_batch_doc (10, 3) \gset
SELECT i ->> 'decision' AS decision, i ->> 'reason' AS reason, i ->> 'trials' AS trials
  FROM json_array_elements((:'body')::json -> 'items') i
 WHERE i ->> 'kind' = 'verdict' AND i ->> 'model_id' = '20000000-0000-0000-0000-000000000004';
ROLLBACK;
\echo '--- promotion in the reverse order: v4 activated before v2 is demoted, under the deferred one-active constraint (expect INSERT 0 2; v2 superseded, v4 active; epoch 3)'
EXECUTE p_insert (2, '50000000-0000-0000-0000-000000000001', 60, '70000000-0000-0000-0000-000000000001',
  '{20000000-0000-0000-0000-000000000004,10000000-0000-0000-0000-000000000001}',
  '20000000-0000-0000-0000-000000000004', gen_random_uuid(), 5);
SELECT id AS m60 FROM matches WHERE seed = 60 \gset
EXECUTE k_claim ('sha256:e2', '30000000-0000-0000-0000-000000000008', 60, 4, 'c1000000-0000-0000-0000-000000000001', 1000, 1000, 5);
EXECUTE k_start ('30000000-0000-0000-0000-000000000008', 'c1000000-0000-0000-0000-000000000001', :'m60');
EXECUTE k_finish ('30000000-0000-0000-0000-000000000008', :'m60',
  '[{"seat":0,"rank":1,"score":8,"strikes":0},{"seat":1,"rank":2,"score":2,"strikes":0}]',
  'all_food', 90, now() - interval '2.5 seconds', 'sha256:e2', '1.8.1', 'replays/ants/w/t7.json', 'c1000000-0000-0000-0000-000000000001', NULL);
\echo '--- a trial played but not yet decided is still live, as matches_one_live_trial_uniq counts it: the trial read does not offer v4 a second one (expect n 0)'
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
\echo '--- and it is nobody''s but its owner''s yet: a trial finished and not yet decided is no public match, and its verified candidate no public version (expect 60 f, then 0 rows)'
SELECT m.seed, match_public(m) FROM matches m WHERE m.seed = 60;
EXECUTE v_public ('20000000-0000-0000-0000-000000000004', 2.0, NULL, NULL);
\echo '--- comments: a link holds a reply; approval audits it and tells the parent''s author once; too fast; a lock refuses (expect INSERT 0 1 x2, held link, INSERT 0 1, INSERT 0 1 then 0, INSERT 0 0 wait_s 15, INSERT 0 1, INSERT 0 0 locked t), rolled back'
BEGIN;
INSERT INTO sessions (sid, user_id, expires_at) VALUES
  ('5e000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', now() + interval '1 day'),
  ('5e000000-0000-0000-0000-0000000000ad', '00000000-0000-0000-0000-0000000000ad', now() + interval '1 day');
EXECUTE cm_thread ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', NULL, 'e0000000-0000-0000-0000-0000000000a1');
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'nice model', 'c0000000-0000-0000-0000-000000000001');
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-000000000001', 'see https://x.io/y', 'c0000000-0000-0000-0000-000000000002');
SELECT state, hold_tag FROM comments WHERE id = 'c0000000-0000-0000-0000-000000000002';
EXECUTE cm_decide ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', '["c0000000-0000-0000-0000-000000000002"]', 'approve', 'fine');
EXECUTE cm_reply (NULL, '["c0000000-0000-0000-0000-000000000002"]');
EXECUTE cm_reply (NULL, '["c0000000-0000-0000-0000-000000000002"]');
SELECT action, reason FROM audit_log WHERE action = 'comment.approve';
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'again', 'c0000000-0000-0000-0000-000000000003');
EXECUTE cm_why ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'again');
EXECUTE cm_lock ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, true, 'heated');
UPDATE comments SET created_at = created_at - interval '1 minute';
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'hello', 'c0000000-0000-0000-0000-000000000004');
EXECUTE cm_why ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'hello');
\echo '    and the daily limit: alice''s approved reply and 99 more make 100 in a day, and the 101st is refused (expect INSERT 0 0, day_wait_s set and wait_s null); and the trigger counted every live comment on the thread (expect 101)'
UPDATE threads SET locked_at = NULL, locked_by = NULL;
INSERT INTO comments (id, thread_id, root_id, author_id, body, created_at)
SELECT g.id, t.id, g.id, '00000000-0000-0000-0000-0000000000a1', 'x', now() - interval '1 hour'
  FROM threads t, (SELECT gen_random_uuid() AS id FROM generate_series(1, 99)) g;
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'the 101st', 'c0000000-0000-0000-0000-000000000005');
EXECUTE cm_why ('00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', NULL, 'e0000000-0000-0000-0000-0000000000a1', NULL, 'x');
SELECT comments FROM threads;
ROLLBACK;
\echo '--- a story edit with a listed word is held: the public keeps the clean text, the owner sees it waiting (expect INSERT 0 1 twice, then How it reads | scam), rolled back'
BEGIN;
INSERT INTO comment_words (word, added_by) VALUES ('scam', '00000000-0000-0000-0000-0000000000ad');
INSERT INTO sessions (sid, user_id, expires_at) VALUES ('5e000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', now() + interval '1 day');
EXECUTE e_story_put ('e0000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', 'How it reads', 'It reads the board.');
EXECUTE e_story_put ('e0000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', 'A scam', 'new text');
SELECT title, hold_tag FROM model_stories;
\echo '    and a listed word in a note is refused and named (expect UPDATE 0, then scam)'
EXECUTE e_note_w ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', 'a scam build');
EXECUTE e_note_r ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-0000000000a1', 'a scam build', 2.0) \gset nr_
SELECT :'nr_note_word' AS note_word;
ROLLBACK;
\echo '--- a post: draft, publish, saved again (date kept), unpublish; each audit line says what changed (expect post.create, post.publish, post.update, post.unpublish, and no public row at the end); Notify: one row per recipient, and the same send again writes nothing; a pick names a public match only (expect INSERT 0 0 for the trial in progress, INSERT 0 1 for m43), rolled back'
BEGIN;
INSERT INTO sessions (sid, user_id, expires_at) VALUES ('5e000000-0000-0000-0000-0000000000ad', '00000000-0000-0000-0000-0000000000ad', now() + interval '1 day');
EXECUTE e_post_c ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'a0000000-0000-0000-0000-000000000001', 'week-two', 'Week two', '# Hello');
EXECUTE e_post_u ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'a0000000-0000-0000-0000-000000000001', NULL, NULL, NULL, true);
EXECUTE e_post_u ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'a0000000-0000-0000-0000-000000000001', NULL, 'Edited', NULL, true);
EXECUTE e_post_u ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'a0000000-0000-0000-0000-000000000001', NULL, NULL, NULL, false);
SELECT action FROM audit_log WHERE target_kind = 'post' ORDER BY at;
EXECUTE e_post_pub ('week-two');
EXECUTE e_send ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'b0000000-0000-0000-0000-000000000001', 'Boards are up', '/maps', '{"everyone": true}');
EXECUTE e_send ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', 'b0000000-0000-0000-0000-000000000001', 'Boards are up', '/maps', '{"everyone": true}');
SELECT count(*) AS rows, count(DISTINCT user_id) AS people, (SELECT recipients FROM notify_sends) AS recorded FROM notifications WHERE kind = 'broadcast';
EXECUTE e_pick_c ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', :'m60');
EXECUTE e_pick_c ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000ad', :'m43');
ROLLBACK;
EXECUTE c_pass_reversed ('2026-09-07 10:00:00+00', 2, :'m60', '20000000-0000-0000-0000-000000000004', 25, 8.333, 2.0);
SELECT v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id
 WHERE e.owner_id = '00000000-0000-0000-0000-0000000000a1' ORDER BY v.version;
SELECT key, epoch FROM clocks WHERE key = 'roster';

\echo '--- the trial read now finds nothing (v4 active); the demand view over the final roster (burst 8, steady 2, settled 3.0)'
\echo '    the baseline 10000000-...-001 is paced like any version (expect placement, want 6: burst 8 less 2 in flight)'
EXECUTE p_trials ('50000000-0000-0000-0000-000000000001', 3);
EXECUTE d_demand ('00000000-0000-0000-0000-00000000000a', 8, 2, 3.0);

\echo '--- pair reads a baseline as it reads anyone. Under a season queue share of 4 the room map names every owner (expect two, alice a1 and the baseline b1, each 2 in flight with room 2), and no want carries a role (expect has_role f)'
SELECT rules AS saved_rules FROM seasons WHERE id = '50000000-0000-0000-0000-000000000001' \gset
UPDATE seasons SET rules = '{"pairing": {"enabled": true, "queue_share_max": 4}}'
 WHERE id = '50000000-0000-0000-0000-000000000001';
EXECUTE p_demand_doc ('50000000-0000-0000-0000-000000000001', 8, 2, 3.0, 64, 0.2) \gset
SELECT e ->> 'model_id' AS model_id, e ->> 'state' AS state, e ->> 'want' AS want, e::jsonb ? 'role' AS has_role
  FROM json_array_elements((:'body')::json -> 'wants') e ORDER BY 1;
SELECT o ->> 'owner_id' AS owner_id, o ->> 'in_flight' AS in_flight, o ->> 'room' AS room
  FROM json_array_elements((:'body')::json -> 'owners') o ORDER BY 1;
UPDATE seasons SET rules = :'saved_rules'::jsonb WHERE id = '50000000-0000-0000-0000-000000000001';

\echo '===== season maps: the one part of a live season that changes ====='
\echo '--- the demand read lists the season''s enabled boards, each with its seats (expect 3: default 2, other-map 2, melee 4)'
EXECUTE p_demand_doc ('50000000-0000-0000-0000-000000000001', 8, 2, 3.0, 64, 0.2) \gset
SELECT (SELECT map_id FROM season_maps WHERE id = (m ->> 'id')::uuid) AS map, m ->> 'players' AS players
  FROM json_array_elements((:'body')::json -> 'limits' -> 'maps') m ORDER BY 1;
\echo '--- disable a board with one match queued on it and one running: the queued one is cancelled MAP_DISABLED and the running one plays on (expect two INSERT 0 2, the flip INSERT 0 1, then cancelled/MAP_DISABLED and running, and one event with cancelled 1)'
BEGIN;
SELECT epoch AS ep FROM clocks WHERE key = 'roster' \gset
EXECUTE p_insert (:ep, '50000000-0000-0000-0000-000000000001', 80, '70000000-0000-0000-0000-000000000002',
  '{20000000-0000-0000-0000-000000000004,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
EXECUTE p_insert (:ep, '50000000-0000-0000-0000-000000000001', 81, '70000000-0000-0000-0000-000000000002',
  '{20000000-0000-0000-0000-000000000004,10000000-0000-0000-0000-000000000001}', NULL, gen_random_uuid(), 5);
UPDATE matches SET status = 'running', claim_token = gen_random_uuid(), lease_expires_at = now() + interval '5 minutes'
 WHERE seed = 81;
EXECUTE m_flip ('ants', 'summer-2026', 'other-map', false, '00000000-0000-0000-0000-0000000000ad');
SELECT seed, status, withdrawn_reason FROM matches WHERE seed IN (80, 81) ORDER BY seed;
SELECT enabled, cancelled FROM season_map_events ORDER BY at;
\echo '    the same state again changes nothing (expect INSERT 0 0); enabled again, a second event (expect INSERT 0 1, events f then t)'
EXECUTE m_flip ('ants', 'summer-2026', 'other-map', false, '00000000-0000-0000-0000-0000000000ad');
EXECUTE m_flip ('ants', 'summer-2026', 'other-map', true, '00000000-0000-0000-0000-0000000000ad');
SELECT enabled, cancelled FROM season_map_events ORDER BY at;
ROLLBACK;
\echo '--- a board name says size-terrain-Np-Hh, and must agree with the file (expect null, map_name_pattern, map_name_players, map_name_hills, and a split name)'
SELECT season_map_name_problem('{"id": "small-open-3p-2h", "players": 3, "rows": 36, "cols": 36, "hills": 6}') AS ok,
       season_map_name_problem('{"id": "basic-small-3p", "players": 3, "rows": 36, "cols": 36, "hills": 3}') AS off_pattern,
       season_map_name_problem('{"id": "small-open-2p-2h", "players": 3, "rows": 36, "cols": 36, "hills": 6}') AS players,
       season_map_name_problem('{"id": "small-open-3p-2h", "players": 3, "rows": 36, "cols": 36, "hills": 3}') AS hills,
       season_map_name('large-cave-4p-3h') AS split;
\echo '--- the upload insert stores a board disabled, its header and name read out of the file, with an audit line (expect INSERT 0 1, then small-open-3p-2h 3 36 36 small open 2 f, map.add); the same board again writes nothing (expect INSERT 0 0)'
BEGIN;
EXECUTE m_insert ('ants', 'summer-2026', '{"id": "small-open-3p-2h", "players": 3, "rows": 36, "cols": 36, "water": [0, 1296], "hills": [[1,1],[2,2],[3,3],[4,4],[5,5],[6,6]]}', '00000000-0000-0000-0000-0000000000ad');
SELECT map_id, players, rows, cols, size, terrain, hills, enabled FROM season_maps WHERE map_id = 'small-open-3p-2h';
SELECT action, target_kind, target_id, detail FROM audit_log WHERE action = 'map.add';
EXECUTE m_insert ('ants', 'summer-2026', '{"id": "small-open-3p-2h", "players": 3, "rows": 36, "cols": 36, "water": [0, 1296], "hills": [[1,1],[2,2],[3,3],[4,4],[5,5],[6,6]]}', '00000000-0000-0000-0000-0000000000ad');
\echo '    ... and nothing for a name off the pattern, which the context read refuses first (expect INSERT 0 0)'
EXECUTE m_insert ('ants', 'summer-2026', '{"id": "basic-small-3p", "players": 3, "rows": 36, "cols": 36, "hills": [[1,1],[2,2],[3,3]]}', '00000000-0000-0000-0000-0000000000ad');
\echo '    ... and nothing into a closed season (expect INSERT 0 0)'
UPDATE seasons SET closed_at = now() WHERE slug = 'summer-2026';
EXECUTE m_insert ('ants', 'summer-2026', '{"id": "another", "players": 2, "rows": 24, "cols": 24}', '00000000-0000-0000-0000-0000000000ad');
ROLLBACK;
\echo '--- the claim sends the board (expect the stand-in board of `default`)'
SELECT m.seed, sm.map_id, sm.board FROM matches m JOIN season_maps sm ON sm.id = m.season_map_id WHERE m.seed = 43;
\echo '===== season baselines: uploaded, admitted, enabled and disabled ====='
\echo '--- a name gives an account (expect baseline.scout, baseline.fire-ant, then null for a name with no slug and for 49 characters)'
SELECT baseline_handle('Scout') AS scout, baseline_handle('  Fire Ant ') AS fire_ant,
       baseline_handle('🔥 🔥') IS NULL AS emoji_null, baseline_handle(repeat('a', 49)) IS NULL AS long_null;
BEGIN;
\echo '--- the upload makes the account, its entry and a TESTING version, with an upload event (expect INSERT 0 1, then baseline.scout Scout v1 testing, 1 event)'
EXECUTE b_insert ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '00000000-0000-0000-0000-0000000000ad');
SELECT u.handle, e.name, v.version, v.status, (SELECT count(*) FROM baseline_events be WHERE be.version_id = v.id AND be.action = 'upload') AS events
  FROM model_versions v JOIN models e ON e.id = v.model_id JOIN users u ON u.id = e.owner_id WHERE u.handle = 'baseline.scout';
SELECT v.id AS scout_v FROM model_versions v JOIN models e ON e.id = v.model_id JOIN users u ON u.id = e.owner_id WHERE u.handle = 'baseline.scout' \gset
\echo '    a re-mint gets what is left of the upload window, the minutes rounded down, and none once it has passed (expect t 1800 30m, t 599 9m, then f)'
EXECUTE b_ctx ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800, 'platform') \gset
SELECT (:'body')::json -> 'existing' ->> 'same' AS same \gset
EXECUTE b_fetch ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800) \gset
SELECT :'same' AS same, :upload_s AS upload_s, :'upload_expires_in' AS expires_in;
UPDATE model_versions SET created_at = now() - interval '1201 seconds' WHERE id = :'scout_v';
EXECUTE b_ctx ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800, 'platform') \gset
SELECT (:'body')::json -> 'existing' ->> 'same' AS same \gset
EXECUTE b_fetch ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800) \gset
SELECT :'same' AS same, :upload_s AS upload_s, :'upload_expires_in' AS expires_in;
UPDATE model_versions SET created_at = now() - interval '2 hours' WHERE id = :'scout_v';
EXECUTE b_ctx ('ants', 'summer-2026', 'Scout', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800, 'platform') \gset
SELECT (:'body')::json -> 'existing' ->> 'same' AS same;
UPDATE model_versions SET created_at = now() WHERE id = :'scout_v';
\echo '    one version a name a season: the same name in another case, other weights (expect INSERT 0 0)'
EXECUTE b_insert ('ants', 'summer-2026', 'SCOUT', 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '00000000-0000-0000-0000-0000000000ad');
\echo '    one set of weights under a second name is a second baseline (expect INSERT 0 1, 2 accounts on those weights)'
EXECUTE b_insert ('ants', 'summer-2026', 'Twin', 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '00000000-0000-0000-0000-0000000000ad');
SELECT count(DISTINCT e.owner_id) AS accounts FROM model_versions v JOIN models e ON e.id = v.model_id WHERE v.weights_hash = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
\echo '--- admission lands a baseline DISABLED and a competitor VERIFIED, each on its prepared admission (expect UPDATE 1 and INSERT 0 1 for each, then disabled / verified)'
UPDATE model_versions SET admit_token = '0a000000-0000-0000-0000-000000000001', admit_started_at = now() WHERE id = :'scout_v';
INSERT INTO admissions (version_id, registration, manifest, artifact_bytes, budget_ops) VALUES (:'scout_v', '{}', '{}', 12000, 1000000);
EXECUTE a_verify (:'scout_v', 'nano', 12000, 3000, 8000.5, '1.8.1', '0a000000-0000-0000-0000-000000000001', '{}', 0);
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'alt');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, weights_hash, manifest_hash, admit_token, admit_started_at)
VALUES ('20000000-0000-0000-0000-0000000000a9', 'e0000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000000a',
        '50000000-0000-0000-0000-000000000001', 1, 'sha256:walt', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '0a000000-0000-0000-0000-000000000002', now());
INSERT INTO admissions (version_id, registration, manifest, artifact_bytes, budget_ops) VALUES ('20000000-0000-0000-0000-0000000000a9', '{}', '{}', 12000, 1000000);
EXECUTE a_verify ('20000000-0000-0000-0000-0000000000a9', 'nano', 12000, 3000, 8000.5, '1.8.1', '0a000000-0000-0000-0000-000000000002', '{}', 0);
SELECT (SELECT status FROM model_versions WHERE id = :'scout_v') AS scout, (SELECT status FROM model_versions WHERE id = '20000000-0000-0000-0000-0000000000a9') AS alt,
       (SELECT model_phase(v) FROM model_versions v WHERE id = :'scout_v') AS phase;
\echo '--- a testing baseline cannot be enabled (expect INSERT 0 0, twin still testing)'
EXECUTE b_flip ('ants', 'summer-2026', 'twin', true, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
SELECT v.status FROM model_versions v JOIN models e ON e.id = v.model_id WHERE e.name = 'Twin';
\echo '--- enabling seeds one Open rating at the prior with its seq-0 event and moves the roster epoch (expect INSERT 0 1, active, 1 rating at 25, 1 event, epoch moved, season_json enabled 2 -- random and scout -- admitting 1)'
SELECT epoch AS ep0 FROM clocks WHERE key = 'roster' \gset
EXECUTE b_flip ('ants', 'summer-2026', 'scout', true, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
SELECT v.status, (SELECT count(*) FROM ratings r WHERE r.version_id = v.id AND r.mu = 25) AS ratings,
       (SELECT count(*) FROM rating_events x WHERE x.version_id = v.id AND x.seq = 0) AS events,
       (SELECT epoch FROM clocks WHERE key = 'roster') > :ep0 AS epoch_moved
  FROM model_versions v WHERE v.id = :'scout_v';
SELECT season_json(s) -> 'baselines' AS baselines FROM seasons s WHERE s.slug = 'summer-2026';
\echo '    on the open ladder now (expect t); the same state again changes nothing (expect INSERT 0 0)'
SELECT EXISTS (SELECT 1 FROM ladder_field('50000000-0000-0000-0000-000000000001', 'open') f WHERE f.version_id = :'scout_v') AS on_ladder;
EXECUTE b_flip ('ants', 'summer-2026', 'scout', true, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
\echo '--- disabling cancels the queued match seating it and lets the running one play on (expect two INSERT 0 2, the flip INSERT 0 1, then 90 cancelled BASELINE_DISABLED and 91 running, disable cancelled 1, off the ladder)'
SELECT epoch AS ep FROM clocks WHERE key = 'roster' \gset
EXECUTE p_insert (:ep, '50000000-0000-0000-0000-000000000001', 90, '70000000-0000-0000-0000-000000000001', ARRAY[:'scout_v', '10000000-0000-0000-0000-000000000001']::uuid[], NULL, gen_random_uuid(), 5);
EXECUTE p_insert (:ep, '50000000-0000-0000-0000-000000000001', 91, '70000000-0000-0000-0000-000000000001', ARRAY[:'scout_v', '10000000-0000-0000-0000-000000000001']::uuid[], NULL, gen_random_uuid(), 5);
UPDATE matches SET status = 'running', claim_token = gen_random_uuid(), lease_expires_at = now() + interval '5 minutes' WHERE seed = 91;
EXECUTE b_flip ('ants', 'summer-2026', 'scout', false, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
SELECT seed, status, withdrawn_reason FROM matches WHERE seed IN (90, 91) ORDER BY seed;
SELECT action, cancelled FROM baseline_events WHERE version_id = :'scout_v' ORDER BY at;
SELECT EXISTS (SELECT 1 FROM ladder_field('50000000-0000-0000-0000-000000000001', 'open') f WHERE f.version_id = :'scout_v') AS on_ladder;
\echo '    a disabled seat can be paired no longer (expect INSERT 0 0)'
SELECT epoch AS ep FROM clocks WHERE key = 'roster' \gset
EXECUTE p_insert (:ep, '50000000-0000-0000-0000-000000000001', 92, '70000000-0000-0000-0000-000000000001', ARRAY[:'scout_v', '10000000-0000-0000-0000-000000000001']::uuid[], NULL, gen_random_uuid(), 5);
\echo '--- enabling it again keeps its ratings (expect INSERT 0 1, still 2 rating rows and 2 seq-0 events)'
UPDATE ratings SET mu = 27 WHERE version_id = :'scout_v';
EXECUTE b_flip ('ants', 'summer-2026', 'scout', true, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
SELECT count(*) AS ratings, min(mu) AS mu FROM ratings WHERE version_id = :'scout_v';
SELECT count(*) AS events FROM rating_events WHERE version_id = :'scout_v' AND seq = 0;
\echo '--- a rejected upload frees its name (expect INSERT 0 1, then Twin v1 rejected and v2 testing)'
UPDATE model_versions v SET status = 'rejected', reject_reason = 'ARTIFACT_MISSING' FROM models e WHERE e.id = v.model_id AND e.name = 'Twin';
EXECUTE b_insert ('ants', 'summer-2026', 'twin', 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '00000000-0000-0000-0000-0000000000ad');
SELECT v.version, v.status FROM model_versions v JOIN models e ON e.id = v.model_id WHERE e.name = 'Twin' ORDER BY v.version;
\echo '--- nothing is uploaded into, enabled or disabled in a closed season (expect INSERT 0 0 twice)'
UPDATE seasons SET closed_at = now() WHERE slug = 'summer-2026';
EXECUTE b_insert ('ants', 'summer-2026', 'Late', 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', '00000000-0000-0000-0000-0000000000ad');
EXECUTE b_flip ('ants', 'summer-2026', 'scout', false, '00000000-0000-0000-0000-0000000000ad', 25.0, 8.333333333333334);
ROLLBACK;
\echo '===== admission: prepared here, admitted on a runner, decided here ====='
BEGIN;
UPDATE games SET reference_observations = '[{"o": 1}, {"o": 2}, {"o": 3}]' WHERE id = '00000000-0000-0000-0000-00000000000a';
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'queued'),
  ('e0000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'crashes');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, weights_hash, manifest_hash) VALUES
  ('20000000-0000-0000-0000-0000000000c1', 'e0000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a',
   '50000000-0000-0000-0000-000000000001', 1, 'sha256:wc1', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'),
  ('20000000-0000-0000-0000-0000000000c2', 'e0000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-00000000000a',
   '50000000-0000-0000-0000-000000000001', 1, 'sha256:wc2', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
\echo '--- prepare: the clock claims both, queues both, releases both (expect claimed t t, INSERT 0 1 twice, UPDATE 1 twice, then queued queued)'
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000001', 16, 180);
SELECT admit_token = '0b000000-0000-0000-0000-000000000001' AS claimed FROM model_versions WHERE id IN ('20000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c2') ORDER BY id;
\echo '    and the batch tells it which of them may still be arriving, so a bucket missing a file is a retry and not a rejection (expect c1 t, c2 f)'
UPDATE model_versions SET created_at = now() - interval '2 hours' WHERE id = '20000000-0000-0000-0000-0000000000c2';
EXECUTE a_batch_doc ('0b000000-0000-0000-0000-000000000001', 13, 19, '[]', 'tb.v', 1800) \gset
SELECT right(i ->> 'model_id', 2) AS version, i ->> 'uploading' AS uploading
  FROM json_array_elements((:'body')::json -> 'items') i ORDER BY 1;
\echo '    and the same two hashes POSTed again are a re-mint only inside that window (expect c1 t, c2 f)'
EXECUTE s_why ('ants', '00000000-0000-0000-0000-0000000000a1', 'sha256:wc1', 'e0000000-0000-0000-0000-0000000000c1', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800, NULL, '00000000-0000-0000-0000-00000000005e', NULL) \gset
SELECT (:'body')::json ->> 'same_submission' AS c1 \gset
EXECUTE s_why ('ants', '00000000-0000-0000-0000-0000000000a1', 'sha256:wc2', 'e0000000-0000-0000-0000-0000000000c2', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a', 1800, NULL, '00000000-0000-0000-0000-00000000005e', NULL) \gset
SELECT :'c1' AS c1, (:'body')::json ->> 'same_submission' AS c2;
UPDATE model_versions SET created_at = now() WHERE id = '20000000-0000-0000-0000-0000000000c2';
EXECUTE a_queue ('20000000-0000-0000-0000-0000000000c1', '{"name": "tb.v20000000-0000-0000-0000-0000000000c1"}', '{}', 5000, 1000000, '0b000000-0000-0000-0000-000000000001');
EXECUTE a_queue ('20000000-0000-0000-0000-0000000000c2', '{"name": "tb.v20000000-0000-0000-0000-0000000000c2"}', '{}', 5000, 1000000, '0b000000-0000-0000-0000-000000000001');
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c1', '0b000000-0000-0000-0000-000000000001');
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c2', '0b000000-0000-0000-0000-000000000001');
SELECT model_phase(v) FROM model_versions v WHERE id IN ('20000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c2') ORDER BY id;
\echo '    a queued submission is the runner''s: the clock does not claim it again, and a lapsed stale claim queues nothing (expect not re-claimed t t, INSERT 0 0)'
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000002', 16, 180);
SELECT admit_token IS NULL AS not_reclaimed FROM model_versions WHERE id IN ('20000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c2') ORDER BY id;
EXECUTE a_queue ('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 1, 1, '0b000000-0000-0000-0000-000000000001');
\echo '    waiting on a runner spends nothing, so nothing expires (expect UPDATE 0)'
EXECUTE a_expire (3, 180, '0b000000-0000-0000-0000-00000000000e');
\echo '--- the runner claims AS runner_gate: oldest first, one attempt spent, the registration, key, digest, budget and the first two observations (expect UPDATE 1, then the claim)'
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000001', 300, 3);
\echo '--- anything waiting at all, leased or not, is what the idle marker asks (expect t while a row is claimed)'
EXECUTE g_admit_waiting;
EXECUTE g_admit_row ('0c000000-0000-0000-0000-000000000001', 'tb.v', 2, 5000);
\echo '    a second runner takes the other one, and a third finds nothing (expect UPDATE 1, UPDATE 0); a revoked runner claims nothing (expect UPDATE 0)'
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000002', '0c000000-0000-0000-0000-000000000002', 300, 3);
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000003', 300, 3);
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000003', '0c000000-0000-0000-0000-000000000004', 300, 3);
\echo '    the role reports and decides nothing: a verdict column and the prepared manifest are refused (expect permission denied twice)'
SAVEPOINT denied;
UPDATE model_versions SET status = 'verified' WHERE id = '20000000-0000-0000-0000-0000000000c1';
ROLLBACK TO SAVEPOINT denied;
UPDATE admissions SET manifest = 'x' WHERE version_id = '20000000-0000-0000-0000-0000000000c1';
ROLLBACK TO SAVEPOINT denied;
RESET ROLE;
SELECT model_phase(v) FROM model_versions v WHERE id = '20000000-0000-0000-0000-0000000000c1';
\echo '--- the report: a stranger''s token writes nothing and is not mine (expect UPDATE 0, mine f); the holder''s lands (expect UPDATE 1); again is a duplicate (expect UPDATE 0, mine t reported t)'
SET ROLE runner_gate;
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c1', '0c000000-0000-0000-0000-000000000009', '{"state": "passed"}', '{}', '{}', 'c1000000-0000-0000-0000-000000000001');
EXECUTE g_admit_why ('20000000-0000-0000-0000-0000000000c1', '0c000000-0000-0000-0000-000000000009');
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c1', '0c000000-0000-0000-0000-000000000001',
  '{"state": "passed", "stage": null, "reason": null}',
  '{"parameters": 3000, "opset": 17, "operators": ["Conv", "Relu"], "probe_dims": {"H": 24}, "artifact_bytes": 5000.0}',
  '{"ok": true, "over_budget": false, "reason": null, "ops_max": 900, "infer_us_max": 8000.5, "checked": 2, "errored": false}',
  'c1000000-0000-0000-0000-000000000001');
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c1', '0c000000-0000-0000-0000-000000000001', '{"state": "failed"}', '{}', '{}', 'c1000000-0000-0000-0000-000000000001');
EXECUTE g_admit_why ('20000000-0000-0000-0000-0000000000c1', '0c000000-0000-0000-0000-000000000001');
RESET ROLE;
\echo '--- the facts the clock judges (expect admitted, no again, size 5002, 3000 params, opset 17, probe ok over 2, infer_us 8000)'
SELECT admission_facts(a) FROM admissions a WHERE a.version_id = '20000000-0000-0000-0000-0000000000c1';
\echo '--- decide: the reported one is claimed again, the waiting one is not; the verdict takes the prepared manifest (expect claimed t, not f; UPDATE 1; verified nano 5002, memory 0, with manifest {} and an admission)'
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000003', 16, 180);
SELECT id = '20000000-0000-0000-0000-0000000000c1' AS reported, admit_token IS NOT NULL AS claimed FROM model_versions WHERE id IN ('20000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c2') ORDER BY id;
EXECUTE a_verify ('20000000-0000-0000-0000-0000000000c1', 'nano', 5002, 3000, 8000, '1.8.1', '0b000000-0000-0000-0000-000000000003', '{"H": 24}', 0);
SELECT status, weight_class, size_bytes, memory_bytes, manifest, model_phase(v) FROM model_versions v WHERE id = '20000000-0000-0000-0000-0000000000c1';
\echo '--- a report that decided nothing goes back with its attempt spent (expect UPDATE 1, UPDATE 1, UPDATE 1; then no report, PROBE_TOO_SLOW, 1 attempt, 1 slow probe, infer_us 277100, queued)'
SET ROLE runner_gate;
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c2', '0c000000-0000-0000-0000-000000000002',
  '{"state": "failed", "stage": "probe", "reason": "the probe inference took 277.1 ms (median of 5), over models.max_probe_ms (250)"}', '{}', NULL,
  'c1000000-0000-0000-0000-000000000002');
RESET ROLE;
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000004', 16, 180);
EXECUTE a_requeue ('20000000-0000-0000-0000-0000000000c2', '0b000000-0000-0000-0000-000000000004', 'PROBE_TOO_SLOW', 277100);
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c2', '0b000000-0000-0000-0000-000000000004');
SELECT a.report IS NULL AS no_report, a.requeued_for, a.attempts, a.slow_probes, v.infer_us, model_phase(v) FROM admissions a JOIN model_versions v ON v.id = a.version_id WHERE a.version_id = '20000000-0000-0000-0000-0000000000c2';
\echo '--- a submission that crashes every runner runs out of attempts: two lapsed leases more, then no claim, then the expiry (expect UPDATE 1, UPDATE 1, UPDATE 0, UPDATE 1, then rejected TIMED_OUT -- one slow probe in three attempts is a busy runner, not the model)'
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000005', 300, 3);
RESET ROLE;
UPDATE admissions SET lease_expires_at = now() - interval '1 second' WHERE version_id = '20000000-0000-0000-0000-0000000000c2';
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000006', 300, 3);
RESET ROLE;
UPDATE admissions SET lease_expires_at = now() - interval '1 second' WHERE version_id = '20000000-0000-0000-0000-0000000000c2';
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000007', 300, 3);
RESET ROLE;
EXECUTE a_expire (3, 180, '0b000000-0000-0000-0000-00000000000f');
SELECT status, reject_reason FROM model_versions WHERE id = '20000000-0000-0000-0000-0000000000c2';
\echo '--- a submission slow on EVERY attempt is refused for it: three probes over the ceiling, each measured, then the expiry (expect probe_us 1312700; UPDATE 1 at each requeue; 3 attempts 3 slow; UPDATE 1, then rejected PROBE_TOO_SLOW with infer_us 1298400)'
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'slow');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, weights_hash, manifest_hash) VALUES
  ('20000000-0000-0000-0000-0000000000c3', 'e0000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-00000000000a',
   '50000000-0000-0000-0000-000000000001', 1, 'sha256:wc3', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000010', 16, 180);
EXECUTE a_queue ('20000000-0000-0000-0000-0000000000c3', '{"name": "tb.v20000000-0000-0000-0000-0000000000c3"}', '{}', 5000, 1000000, '0b000000-0000-0000-0000-000000000010');
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000010');
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000011', 300, 3);
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c3', '0c000000-0000-0000-0000-000000000011',
  '{"state": "failed", "stage": "probe", "reason": "the probe inference took 1312.7 ms (median of 5), over models.max_probe_ms (1000)"}', '{}', NULL,
  'c1000000-0000-0000-0000-000000000001');
RESET ROLE;
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000011', 16, 180);
EXECUTE a_batch_doc ('0b000000-0000-0000-0000-000000000011', 13, 19, '[]', 'tb.v', 1800) \gset
SELECT i #>> '{job,again}' AS again, i ->> 'probe_us' AS probe_us FROM json_array_elements((:'body')::json -> 'items') i;
EXECUTE a_requeue ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000011', 'PROBE_TOO_SLOW', 1312700);
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000011');
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000012', 300, 3);
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c3', '0c000000-0000-0000-0000-000000000012',
  '{"state": "failed", "stage": "probe", "reason": "the probe inference took 1305.2 ms (median of 5), over models.max_probe_ms (1000)"}', '{}', NULL,
  'c1000000-0000-0000-0000-000000000001');
RESET ROLE;
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000012', 16, 180);
EXECUTE a_requeue ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000012', 'PROBE_TOO_SLOW', 1305200);
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000012');
SET ROLE runner_gate;
EXECUTE g_admit_claim ('c1000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000013', 300, 3);
EXECUTE g_admit_report ('20000000-0000-0000-0000-0000000000c3', '0c000000-0000-0000-0000-000000000013',
  '{"state": "failed", "stage": "probe", "reason": "the probe inference took 1298.4 ms (median of 5), over models.max_probe_ms (1000)"}', '{}', NULL,
  'c1000000-0000-0000-0000-000000000001');
RESET ROLE;
EXECUTE a_claim ('0b000000-0000-0000-0000-000000000013', 16, 180);
EXECUTE a_requeue ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000013', 'PROBE_TOO_SLOW', 1298400);
EXECUTE a_release ('20000000-0000-0000-0000-0000000000c3', '0b000000-0000-0000-0000-000000000013');
SELECT a.attempts, a.slow_probes FROM admissions a WHERE a.version_id = '20000000-0000-0000-0000-0000000000c3';
EXECUTE a_expire (3, 180, '0b000000-0000-0000-0000-000000000014');
SELECT status, reject_reason, infer_us FROM model_versions WHERE id = '20000000-0000-0000-0000-0000000000c3';
\echo '--- whose fault, on Orion''s stage (expect: DIGEST_FAILED refused; ARTIFACT_UNREACHABLE, ADMISSION_TIMED_OUT, PROBE_TOO_SLOW, ADMISSION_UNREACHABLE again; PARSE_FAILED refused)'
SELECT r.label, admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1, r.report, now(), NULL, 0)::admissions) ->> 'refused' AS refused,
       admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1, r.report, now(), NULL, 0)::admissions) ->> 'again' AS again
  FROM (VALUES
    (1, 'digest',  '{"admission": {"state": "failed", "stage": "digest", "reason": "the bytes hash to something else"}}'::jsonb),
    (2, 'fetch',   '{"admission": {"state": "failed", "stage": "fetch", "reason": "connection reset"}}'::jsonb),
    (3, 'late',    '{"admission": {"state": "failed", "stage": "fetch", "reason": "admission exceeded models.admission_timeout_secs (120) during fetch"}}'::jsonb),
    (4, 'slow',    '{"admission": {"state": "failed", "stage": "probe", "reason": "over models.max_probe_ms (250)"}}'::jsonb),
    (5, 'nothing', '{"stats": {}}'::jsonb),
    (6, 'parse',   '{"admission": {"state": "failed", "stage": "parse", "reason": "the graph does not read"}}'::jsonb)) AS r (n, label, report)
 ORDER BY r.n;
\echo '--- a malformed report is missing facts, never a cast error (expect parameters null, opset 13, size 102, operators [], probe null -- it evaluated nothing)'
SELECT admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1,
  '{"admission": {"state": "passed"}, "stats": {"parameters": "lots", "opset": 13.9, "operators": "Conv", "artifact_bytes": 1e30}, "probe": {"ok": true, "checked": 0, "reason": "EVIL"}}',
  now(), NULL, 0)::admissions);
ROLLBACK;

\echo '===== memory: a class allows it, admission prices it, the round trip judges it ====='
BEGIN;
\echo '--- the class memory numbers: whole numbers to 262144 and 16, absent is 0 (expect t t t, then f for each of the eight)'
SELECT weight_classes_ok('[{"class": "nano", "max_bytes": 16384, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}]') AS tops,
       weight_classes_ok('[{"class": "nano", "max_bytes": 16384, "memory_flat_bytes": 0, "memory_cell_bytes": 0}]') AS zeros,
       weight_classes_ok('[{"class": "nano", "max_bytes": 16384}]') AS absent;
SELECT r.label, weight_classes_ok(jsonb_build_array('{"class": "nano", "max_bytes": 16384}'::jsonb || r.e)) AS ok
  FROM (VALUES (1, 'flat over',  '{"memory_flat_bytes": 262145}'::jsonb),
               (2, 'cell over',  '{"memory_cell_bytes": 17}'::jsonb),
               (3, 'negative',   '{"memory_flat_bytes": -1}'::jsonb),
               (4, 'fraction',   '{"memory_cell_bytes": 1.5}'::jsonb),
               (5, 'a string',   '{"memory_flat_bytes": "1024"}'::jsonb),
               (6, 'null',       '{"memory_cell_bytes": null}'::jsonb),
               (7, 'a list',     '{"memory_flat_bytes": [1]}'::jsonb),
               (8, 'cell -1',    '{"memory_cell_bytes": -1}'::jsonb)) AS r (n, label, e)
 ORDER BY r.n;
\echo '    and the column refuses one (expect check violation on seasons_weight_classes_shape)'
SAVEPOINT bounds;
UPDATE seasons SET weight_classes = '[{"class": "nano", "max_bytes": 16384, "memory_cell_bytes": 17}]'
 WHERE id = '50000000-0000-0000-0000-000000000001';
ROLLBACK TO SAVEPOINT bounds;
\echo '--- the default table allows no memory, and says so (expect valid t, 5 classes, 5 at 0 and 0); a table without the keys reads as 0 (expect nano 16384 0 0)'
SELECT weight_classes_ok(default_weight_classes()) AS valid, jsonb_array_length(default_weight_classes()) AS classes,
       (SELECT count(*) FROM jsonb_array_elements(default_weight_classes()) e
         WHERE e -> 'memory_flat_bytes' = '0'::jsonb AND e -> 'memory_cell_bytes' = '0'::jsonb) AS zero_memory;
SELECT e ->> 'class' AS class, e ->> 'max_bytes' AS max_bytes, e ->> 'memory_flat_bytes' AS flat, e ->> 'memory_cell_bytes' AS cell
  FROM jsonb_array_elements(weight_classes_public('[{"class": "nano", "max_bytes": 16384}]')) e;

\echo '--- pricing, on the Ants envelope (576 and 14880 cells). `memory` [1,2,H,W] f32 and `ant_memory` [1,N,4] f32 are 6 elements, 24 bytes a cell: 13824 and 357120 bytes'
\echo '    (expect: none 0 0 null; board+ants in large 13824 357120 null; in a small class TOO_LARGE; in nano NOT_ALLOWED; a fixed 280000 over the cap at 576 cells only TOO_LARGE; fixed 32 in a flat-only class null)'
SELECT r.label, p.fixed_elems, p.cell_elems, p.fixed_bytes, p.cell_bytes, p.cells_min, p.cells_max, p.bytes_min, p.bytes_max, p.verdict
  FROM (VALUES
    (1, 'none',       '{"outputs": [{"name": "policy", "dtype": "f32", "shape": [1, 5, "H", "W"]}]}'::jsonb,
                      '{"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}'::jsonb),
    (2, 'board+ants', '{"outputs": [{"name": "policy", "dtype": "f32", "shape": [1, 5, "H", "W"]},
                                    {"name": "memory", "dtype": "f32", "shape": [1, 2, "H", "W"]},
                                    {"name": "ant_memory", "dtype": "f32", "shape": [1, "N", 4]}]}',
                      '{"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}'),
    (3, 'small cap',  '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 2, "H", "W"]},
                                    {"name": "ant_memory", "dtype": "f32", "shape": [1, "N", 4]}]}',
                      '{"class": "micro", "max_bytes": 131072, "memory_flat_bytes": 4096, "memory_cell_bytes": 2}'),
    (4, 'nano',       '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 2, "H", "W"]}]}',
                      '{"class": "nano", "max_bytes": 16384}'),
    (5, 'min end',    '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 70000]}]}',
                      '{"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}'),
    (6, 'flat only',  '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 8]}]}',
                      '{"class": "nano", "max_bytes": 16384, "memory_flat_bytes": 1024, "memory_cell_bytes": 0}')) AS r (n, label, m, c),
       memory_price(r.m, '{"players": [2, 8], "sides": [24, 124], "cells_max": 14880}', r.c) p
 ORDER BY r.n;
\echo '    widths: i8 1, f16 2, f64 8, bool 1 (expect cell_bytes 1 2 8, fixed 3)'
SELECT (memory_price('{"outputs": [{"name": "memory", "dtype": "i8", "shape": [1, 1, "H", "W"]}]}', '{"sides": [24, 124], "cells_max": 14880}', '{"memory_cell_bytes": 16}')).cell_bytes AS i8,
       (memory_price('{"outputs": [{"name": "memory", "dtype": "f16", "shape": [1, 1, "H", "W"]}]}', '{"sides": [24, 124], "cells_max": 14880}', '{"memory_cell_bytes": 16}')).cell_bytes AS f16,
       (memory_price('{"outputs": [{"name": "memory", "dtype": "f64", "shape": [1, 1, "H", "W"]}]}', '{"sides": [24, 124], "cells_max": 14880}', '{"memory_cell_bytes": 16}')).cell_bytes AS f64,
       (memory_price('{"outputs": [{"name": "memory", "dtype": "bool", "shape": [3]}]}', '{"sides": [24, 124], "cells_max": 14880}', '{"memory_flat_bytes": 16}')).fixed_bytes AS bool;
\echo '--- MEMORY_SHAPE (expect MEMORY_SHAPE for all ten)'
SELECT r.label, (memory_price(r.m, '{"players": [2, 8], "sides": [24, 124], "cells_max": 14880}',
                              '{"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}')).verdict
  FROM (VALUES
    (1,  'three named',     '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, "C", "H", "W"]}]}'::jsonb),
    (2,  'a name twice',    '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, "H", "H"]}]}'),
    (3,  'ants: two named', '{"outputs": [{"name": "ant_memory", "dtype": "f32", "shape": [1, "N", "K"]}]}'),
    (4,  'no dtype',        '{"outputs": [{"name": "memory", "shape": [1, 8]}]}'),
    (5,  'unknown dtype',   '{"outputs": [{"name": "memory", "dtype": "f8", "shape": [1, 8]}]}'),
    (6,  'no shape',        '{"outputs": [{"name": "memory", "dtype": "f32"}]}'),
    (7,  'a zero',          '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 0]}]}'),
    (8,  'a fraction',      '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 1.5]}]}'),
    (9,  'an empty name',   '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, ""]}]}'),
    (10, 'declared twice',  '{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 8]},
                                          {"name": "memory", "dtype": "f32", "shape": [1, 8]}]}')) AS r (n, label, m)
 ORDER BY r.n;
\echo '    and no declaration overflows (expect MEMORY_TOO_LARGE, not an error)'
SELECT (memory_price('{"outputs": [{"name": "memory", "dtype": "f64", "shape": [2147483647, 2147483647, 1e300, "H"]}]}',
                     '{"players": [2, 8], "sides": [24, 124], "cells_max": 14880}',
                     '{"memory_flat_bytes": 262144, "memory_cell_bytes": 16}')).verdict;
\echo '--- a game with no board envelope prices nothing it cannot: no verdict and no bytes where the class allows memory; none needed without (expect null null, then null 0)'
SELECT (p).verdict, (p).bytes_max FROM (SELECT memory_price('{"outputs": [{"name": "memory", "dtype": "f32", "shape": [1, 2, "H", "W"]}]}', NULL,
                                                         '{"memory_flat_bytes": 1024, "memory_cell_bytes": 2}') AS p) x;
SELECT (p).verdict, (p).bytes_max FROM (SELECT memory_price('{"outputs": [{"name": "policy", "dtype": "f32", "shape": [1, 5, "H", "W"]}]}', NULL,
                                                         '{"memory_flat_bytes": 1024, "memory_cell_bytes": 2}') AS p) x;

\echo '--- the admit clock''s classify prices against the class it lands in (expect nano MEMORY_NOT_ALLOWED; large no verdict 357120; then unpriced t on a game with no envelope)'
UPDATE games SET manifest = '{"limits": {"boards": {"players": [2, 8], "sides": [24, 124], "cells_max": 14880}}}'
 WHERE id = '00000000-0000-0000-0000-00000000000a';
UPDATE seasons SET weight_classes = '[{"class": "nano", "max_bytes": 16384},
                                      {"class": "large", "max_bytes": 67108864, "memory_flat_bytes": 262144, "memory_cell_bytes": 16}]'
 WHERE id = '50000000-0000-0000-0000-000000000001';
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'remembers');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, weights_hash, manifest_hash, admit_token, admit_started_at) VALUES
  ('20000000-0000-0000-0000-0000000000d1', 'e0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a',
   '50000000-0000-0000-0000-000000000001', 1, 'sha256:wd1', 'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
   '0b000000-0000-0000-0000-0000000000d1', now());
INSERT INTO admissions (version_id, registration, manifest, artifact_bytes, budget_ops) VALUES
  ('20000000-0000-0000-0000-0000000000d1',
   '{"name": "tb.v20000000-0000-0000-0000-0000000000d1",
     "outputs": [{"name": "policy", "dtype": "f32", "shape": [1, 5, "H", "W"]},
                 {"name": "memory", "dtype": "f32", "shape": [1, 2, "H", "W"]},
                 {"name": "ant_memory", "dtype": "f32", "shape": [1, "N", 4]}]}',
   '{}', 20000, 1000000);
EXECUTE a_classify ('20000000-0000-0000-0000-0000000000d1', 5000);
EXECUTE a_classify ('20000000-0000-0000-0000-0000000000d1', 20000);
SAVEPOINT envelope;
UPDATE games SET manifest = '{}' WHERE id = '00000000-0000-0000-0000-00000000000a';
EXECUTE a_classify ('20000000-0000-0000-0000-0000000000d1', 20000);
ROLLBACK TO SAVEPOINT envelope;
\echo '--- the verdict writes the bytes, and the version shows them with its class''s numbers (expect UPDATE 1; large 357120; 262144 16)'
EXECUTE a_verify ('20000000-0000-0000-0000-0000000000d1', 'large', 20000, 3000, 8000, '1.9.1', '0b000000-0000-0000-0000-0000000000d1', '{"H": 24}', 357120);
SELECT version_json(v, 2.0) ->> 'class' AS class, version_json(v, 2.0) ->> 'memory_bytes' AS memory_bytes,
       version_json(v, 2.0) ->> 'class_memory_flat_bytes' AS flat, version_json(v, 2.0) ->> 'class_memory_cell_bytes' AS cell
  FROM model_versions v WHERE v.id = '20000000-0000-0000-0000-0000000000d1';
\echo '    and the season shows its classes with both numbers, 0 where the table left them out (expect nano 0 0, large 262144 16)'
SELECT e ->> 'class' AS class, e ->> 'memory_flat_bytes' AS flat, e ->> 'memory_cell_bytes' AS cell
  FROM seasons s, json_array_elements(season_json(s) -> 'weight_classes') e
 WHERE s.id = '50000000-0000-0000-0000-000000000001';

\echo '--- the round trip, typed from the report (expect: failed 1 MEMORY_ROUND_TRIP {3,1}; clean null {3,0}; no memory null null; malformed null {null,null}; float 2.0 MEMORY_ROUND_TRIP)'
SELECT r.label,
       admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1, r.report, now(), NULL, 0)::admissions) ->> 'round_trip_refused' AS refused,
       admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1, r.report, now(), NULL, 0)::admissions) -> 'probe' -> 'round_trip' AS round_trip
  FROM (VALUES
    (1, 'failed',    '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4, "round_trip": {"checked": 3, "failed": 1}}}'::jsonb),
    (2, 'clean',     '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4, "round_trip": {"checked": 3, "failed": 0}}}'),
    (3, 'no memory', '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4}}'),
    (4, 'malformed', '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4, "round_trip": {"checked": "x", "failed": "lots"}}}'),
    (5, 'float',     '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4, "round_trip": {"checked": 3, "failed": 2.0}}}')) AS r (n, label, report)
 ORDER BY r.n;
\echo '    and the keys the clock already judged on are unchanged beside it (expect admitted t, refused null, again null, probe ok t checked 4)'
SELECT j ->> 'admitted' AS admitted, j ->> 'refused' AS refused, j ->> 'again' AS again,
       j -> 'probe' ->> 'ok' AS ok, j -> 'probe' ->> 'checked' AS checked
  FROM (SELECT admission_facts(ROW('20000000-0000-0000-0000-0000000000c1', '{}', '{}', 100, 1, now(), NULL, NULL, NULL, 1,
          '{"admission": {"state": "passed"}, "probe": {"ok": true, "checked": 4, "round_trip": {"checked": 3, "failed": 1}}}',
          now(), NULL, 0)::admissions) AS j) x;
ROLLBACK;
\echo '--- a season''s slug is its name''s (expect check violation), fixed per game (expect unique violation), and never a route''s word (expect check violation)'
INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, closed_at)
VALUES ('00000000-0000-0000-0000-00000000000a', 7, 'Winter 2026', 'winter', 'sha256:e1',
        now() - interval '9 days', now() - interval '8 days', now() - interval '8 days');
INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, closed_at)
VALUES ('00000000-0000-0000-0000-00000000000a', 7, 'Summer-2026', 'summer-2026', 'sha256:e1',
        now() - interval '9 days', now() - interval '8 days', now() - interval '8 days');
INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, closed_at)
VALUES ('00000000-0000-0000-0000-00000000000a', 7, 'Current', 'current', 'sha256:e1',
        now() - interval '9 days', now() - interval '8 days', now() - interval '8 days');
SELECT season_slug('FireAnts 2026') AS fireants, season_slug('  Summer   2026!! ') AS summer;

\echo '===== the routes preserve the fences the statements carry ====='
-- S2.1. The races below prove the STATEMENTS; these prove that a ROUTE in front of one cannot lose
-- what it carries. Both halves matter now that a runner reaches them over a WAN and can retry.

\echo '--- a stale claim token writes nothing through the route, exactly as through the statement (expect 0)'
-- $1 token, $2 runner, $3 match. A live runner and a real match id, so the ONLY thing wrong is the
-- token -- which is the point: the route hands the same three values to the same statement, and the
-- fence is the statement's, not the route's.
EXECUTE k_start ('00000000-0000-0000-0000-0000000000ff',
                 'c1000000-0000-0000-0000-000000000001',
                 :'m43');

\echo '--- finish is idempotent: the row is already finished and the token still matches, so the'
\echo '    route reads it back and answers applied:false rather than the 409 a lost claim gets.'
\echo '    Both were rows_affected = 0 before, and conflating them fails a healthy runner mid-match.'
SELECT status AS finished_state, (claim_token = '30000000-0000-0000-0000-000000000001') AS token_still_matches
  FROM matches WHERE seed = 42;

\echo '===== identity: (provider, subject) is the account key; the handle is a seeded label ====='

\echo '--- a baseline handle must live in the reserved namespace (expect check violation)'
INSERT INTO users (handle, role) VALUES ('baseline-legacy', 'baseline');

\echo '--- and a human handle must NOT: the reserved namespace is exclusive both ways (expect check violation)'
INSERT INTO users (handle, role) VALUES ('baseline.sneak', 'competitor');

\echo '--- `Alice` and `alice` are one name (expect duplicate key on users_handle_uniq)'
-- Case-sensitive column, case-insensitive readers: the index on lower(handle) is what stops two
-- rows both answering to one name.
INSERT INTO users (handle) VALUES ('Alice');

\echo '--- one account per (provider, subject): a second identity for github/1 collides (expect duplicate key)'
INSERT INTO identities (user_id, provider, subject, login)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'github', '1', 'alice-again');

\echo '--- sign-in on a NEW identity mints an account, handle seeded once from the login (expect octocat / The Octocat)'
EXECUTE u_signin ('github', '4210', 'octocat', 'The Octocat');
EXECUTE u_promote ('github', '4210', '');
SELECT u.handle, u.display_name FROM identities i JOIN users u ON u.id = i.user_id
 WHERE i.provider = 'github' AND i.subject = '4210';

\echo '--- a RETURNING identity keeps its handle and refreshes only the cached login (expect foo / foo-renamed)'
-- github/7000 renamed at the provider; the account (and its handle) is untouched, the login moves.
EXECUTE u_signin ('github', '7000', 'foo', 'Foo');
EXECUTE u_signin ('github', '7000', 'foo-renamed', 'Foo');
SELECT u.handle, i.login FROM identities i JOIN users u ON u.id = i.user_id
 WHERE i.provider = 'github' AND i.subject = '7000';

\echo '--- a login that collides with a taken handle is disambiguated by seed_handle, never a 500 (expect alice-github)'
EXECUTE u_signin ('github', '4211', 'alice', 'Another Alice');
SELECT u.handle FROM identities i JOIN users u ON u.id = i.user_id
 WHERE i.provider = 'github' AND i.subject = '4211';

\echo '--- admin by deployment: a listed provider:subject is promoted at sign-in, only ever promoted (expect admin)'
EXECUTE u_signin ('github', '9000', 'newadmin', NULL);
EXECUTE u_promote ('github', '9000', 'github:9000,github:5');
SELECT u.role FROM identities i JOIN users u ON u.id = i.user_id
 WHERE i.provider = 'github' AND i.subject = '9000';

\echo '===== an entry is a name: unique per owner, and deliberately NOT unique across them ====='

\echo '--- one entry per name per owner, case-insensitively (expect INSERT 0 1, then duplicate key on models_owner_game_name_uniq)'
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT user_id FROM identities WHERE provider = 'github' AND subject = '4210'),
        '00000000-0000-0000-0000-00000000000a', 'brain');
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT user_id FROM identities WHERE provider = 'github' AND subject = '4210'),
        '00000000-0000-0000-0000-00000000000a', 'BRAIN');

\echo '--- and TWO COMPETITORS MAY HOLD ONE NAME (expect INSERT 0 1)'
-- The repository was a GLOBAL key, so `alice/brain` could be entered once platform-wide and a
-- second competitor naming the same repository was refused. A name is not an identity and nothing
-- is decided on one, so there is no cross-owner index here and this insert must SUCCEED. Who a
-- competitor is, is a row in identities (provider, subject) -- sign-in, the whole of what a provider does now.
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT user_id FROM identities WHERE provider = 'github' AND subject = '4211'),
        '00000000-0000-0000-0000-00000000000a', 'brain');

\echo '--- the baselines need no carve-out any more (expect INSERT 0 1)'
-- Three of them shared one repository, which was legal only because models_repo_uniq was PARTIAL on
-- the owner's key. With no repository there is no shared value and no exception to explain.
INSERT INTO users (handle, role) VALUES ('baseline.two', 'baseline');
INSERT INTO models (owner_id, game_id, name)
VALUES ((SELECT id FROM users WHERE handle = 'baseline.two'),
        '00000000-0000-0000-0000-00000000000a', 'two');

\echo '--- and the season rules document no longer has a `repo` block (expect check violation)'
-- It was the one block whose `enabled` defaulted true, because it was the anti-impersonation rule
-- for a field that limited nothing. Removing the field removed the exception with it.
UPDATE seasons SET rules = '{"repo": {"enabled": true, "allow_orgs": ["acme-lab"]}}'::jsonb
 WHERE number = 1;

-- ======================================================================================
-- N30 TENANT FENCES: season_admits (entry + season_participants) and season_visible.
-- Appended last, on its own fixtures, so it perturbs nothing above. A private restricted
-- season beside the public open one, one pinned participant (alice), one season admin (prof),
-- one stranger, and the platform admin (ops).
-- ======================================================================================
INSERT INTO users (id, handle, role) VALUES
  ('00000000-0000-0000-0000-0000000000f1', 'prof',     'competitor'),
  ('00000000-0000-0000-0000-0000000000f2', 'stranger', 'competitor');
INSERT INTO identities (user_id, provider, subject, login) VALUES
  ('00000000-0000-0000-0000-0000000000f1', 'github', '5001', 'prof'),
  ('00000000-0000-0000-0000-0000000000f2', 'github', '5002', 'stranger');
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest,
                     submissions_open_at, submissions_close_at, visibility, entry)
VALUES ('50000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 99,
        'Cohort', 'cohort', 'sha256:e1', now() - interval '1 day', now() + interval '30 days',
        'private', 'restricted');
INSERT INTO season_participants (season_id, provider, login, user_id, added_by)
VALUES ('50000000-0000-0000-0000-0000000000f1', 'github', 'alice',
        '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000ad');
INSERT INTO season_admins (season_id, user_id, added_by)
VALUES ('50000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000ad');

\echo '--- season_admits: open admits anyone (t), restricted admits a listed participant (t) and refuses a stranger (f)'
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS open_anyone
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-000000000001';
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS restricted_participant,
       season_admits(s, '00000000-0000-0000-0000-0000000000f2') AS restricted_stranger
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';

\echo '--- season_visible: public to anonymous (t); private hidden from a stranger (f); shown to its participant, its admin, the platform admin (t t t)'
SELECT season_visible(s, NULL) AS public_anon
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-000000000001';
SELECT season_visible(s, '00000000-0000-0000-0000-0000000000f2') AS private_stranger,
       season_visible(s, '00000000-0000-0000-0000-0000000000a1') AS private_participant,
       season_visible(s, '00000000-0000-0000-0000-0000000000f1') AS private_admin,
       season_visible(s, '00000000-0000-0000-0000-0000000000ad') AS private_platform
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';

\echo '--- providers allow-list: a season restricted to google refuses a pinned github identity (f) until the user has a google one (t)'
UPDATE seasons SET providers = '["google"]'::jsonb WHERE id = '50000000-0000-0000-0000-0000000000f1';
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS github_pinned_refused
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';
INSERT INTO identities (user_id, provider, subject, login)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'google', 'g-alice', 'alice@example.edu');
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS google_admitted
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';
UPDATE seasons SET providers = NULL WHERE id = '50000000-0000-0000-0000-0000000000f1';

\echo '--- the wildcard row admits every identity of its provider: a stranger is admitted (t), and removing it refuses them again (f)'
INSERT INTO season_participants (season_id, provider, login, user_id, added_by)
VALUES ('50000000-0000-0000-0000-0000000000f1', 'github', NULL, NULL,
        '00000000-0000-0000-0000-0000000000ad');
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000f2') AS wildcard_admits
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';
UPDATE season_participants SET removed_at = now()
 WHERE season_id = '50000000-0000-0000-0000-0000000000f1' AND login IS NULL;
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000f2') AS wildcard_gone
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';

\echo '--- a removed participant is refused (f): remove alice, she no longer admits'
UPDATE season_participants SET removed_at = now()
 WHERE season_id = '50000000-0000-0000-0000-0000000000f1' AND lower(login) = 'alice';
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS removed_participant
  FROM seasons s WHERE s.id = '50000000-0000-0000-0000-0000000000f1';

-- N30 the PUBLIC READS gate their per-season rows on visibility (V3/V5), the anonymous half of
-- season_visible: a private season's match, version and medal are hidden exactly as the private
-- season is. `fencer` (alice's) has an active version, a listed rated match and a podium medal in
-- BOTH the public season (0001) and the private cohort (0f1); each gate keeps only the public one.
INSERT INTO season_maps (id, season_id, map_id, players, rows, cols, digest, board, enabled, added_by) VALUES
  ('5a000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'fence', 2, 24, 24, 'sha256:fence', '{"id":"fence"}', true, '00000000-0000-0000-0000-0000000000ad'),
  ('5a000000-0000-0000-0000-0000000000f1', '50000000-0000-0000-0000-0000000000f1', 'fence', 2, 24, 24, 'sha256:fence', '{"id":"fence"}', true, '00000000-0000-0000-0000-0000000000ad');
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'fencer');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, size_bytes, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-0000000000f8', 'e0000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 1, 'active', 'nano', 500, 'sha256:wf8', 'sha256:mf8', '1.8.1'),
  ('20000000-0000-0000-0000-0000000000f9', 'e0000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000f1', 2, 'active', 'nano', 500, 'sha256:wf9', 'sha256:mf9', '1.8.1');
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders, status, listed, played_at, rated_at, rated_seq) VALUES
  ('11111111-1111-1111-1111-1111111111f8', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-000000000001', 'sha256:e1', 1, '5a000000-0000-0000-0000-000000000001', 2, ARRAY['open']::ladder[], 'rated', true, now(), now(), 1),
  ('11111111-1111-1111-1111-1111111111f9', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000f1', 'sha256:e1', 2, '5a000000-0000-0000-0000-0000000000f1', 2, ARRAY['open']::ladder[], 'rated', true, now(), now(), 2);
INSERT INTO season_podium (season_id, ladder, place, version_id, owner_id, rating) VALUES
  ('50000000-0000-0000-0000-000000000001', 'nano', 3, '20000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-0000000000a1', 22),
  ('50000000-0000-0000-0000-0000000000f1', 'open', 1, '20000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-0000000000a1', 22);

\echo '--- match_public: a public season''s listed match shows (t), a private season''s does not (f)'
SELECT match_public(m) AS public_match FROM matches m WHERE m.id = '11111111-1111-1111-1111-1111111111f8';
SELECT match_public(m) AS private_match FROM matches m WHERE m.id = '11111111-1111-1111-1111-1111111111f9';
\echo '--- the public model read shows only the public season''s version (expect public t, private f)'
SELECT s.visibility,
       version_public(mv.status) AND EXISTS (SELECT 1 FROM seasons x WHERE x.id = mv.season_id AND x.visibility = 'public') AS shows
  FROM model_versions mv JOIN seasons s ON s.id = mv.season_id
 WHERE mv.model_id = 'e0000000-0000-0000-0000-0000000000f9' ORDER BY s.visibility;
\echo '--- the public profile shows only the public season''s medal (expect public 1, all 2)'
SELECT count(*) FILTER (WHERE ms.visibility = 'public') AS public_medals, count(*) AS all_medals
  FROM season_podium p JOIN seasons ms ON ms.id = p.season_id
 WHERE p.owner_id = '00000000-0000-0000-0000-0000000000a1'
   AND p.version_id IN ('20000000-0000-0000-0000-0000000000f8', '20000000-0000-0000-0000-0000000000f9');

\echo '===== rounds, the idle fill and the finals: a season whose score is not its versions'' age ====='
-- A season of its own, rolled back at the end: two competitors -- dora's old version with 400
-- games and a settled sigma, eve's new one with ten -- and a baseline, one two-seat board, played
-- in weekly rounds of 4 games with a sigma floor of 3. Everything below walks the shipped
-- statements; the clock and gate calls are made as the clocks make them.
BEGIN;
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, rules)
VALUES ('50000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', 9,
        'Rounds 2026', 'rounds-2026', 'sha256:e1', now() - interval '10 days', now() + interval '10 days',
        '{"rounds": {"enabled": true, "days": 7, "games": 4, "sigma_floor": 3, "warn_minutes": 15}}');
INSERT INTO users (id, handle, role) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'rd-dora', 'competitor'),
  ('00000000-0000-0000-0000-0000000000d2', 'rd-eve', 'competitor'),
  ('00000000-0000-0000-0000-0000000000d3', 'baseline.rd-wall', 'baseline');
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a', 'old hand'),
  ('e0000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000000a', 'newcomer'),
  ('e0000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-00000000000a', 'wall');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-0000000000d1', 'e0000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 1, 'active', 'nano', 'sha256:wd1', 'sha256:md1', '1.8.1'),
  ('20000000-0000-0000-0000-0000000000d2', 'e0000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 1, 'active', 'nano', 'sha256:wd2', 'sha256:md2', '1.8.1'),
  ('10000000-0000-0000-0000-0000000000d3', 'e0000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 1, 'active', 'nano', 'sha256:wd3', 'sha256:md3', '1.8.1');
INSERT INTO ratings (version_id, ladder, mu, sigma, matches_played) VALUES
  ('20000000-0000-0000-0000-0000000000d1', 'open', 30, 0.7, 400),
  ('20000000-0000-0000-0000-0000000000d2', 'open', 32, 1.3, 10),
  ('10000000-0000-0000-0000-0000000000d3', 'open', 26, 1.0, 300);
INSERT INTO season_maps (id, season_id, map_id, players, rows, cols, digest, board, enabled, added_by) VALUES
  ('70000000-0000-0000-0000-0000000000e1', '50000000-0000-0000-0000-0000000000e1', 'rounds-board', 2, 24, 24, 'sha256:re1', '{"id": "rounds-board"}', true, '00000000-0000-0000-0000-0000000000ad');

\echo '--- the schedule: round 1 at the window''s open, born announced (expect INSERT 0 1, then 1 | round | 4 | t | f)'
EXECUTE w_schedule ('00000000-0000-0000-0000-00000000000a');
SELECT n, kind, games, announced_at IS NOT NULL AS announced, applied_at IS NOT NULL AS applied
  FROM season_rounds WHERE season_id = '50000000-0000-0000-0000-0000000000e1';
\echo '--- count starts it under its fence: every sigma raised to the floor 3, mu kept (expect UPDATE 1; then 30 3 | 32 3 | 26 3)'
EXECUTE c_fence ('2026-09-08 00:00:00+00', 1);
EXECUTE c_round ('2026-09-08 00:00:00+00', 1);
SELECT version_id, mu, sigma FROM ratings
 WHERE version_id IN ('20000000-0000-0000-0000-0000000000d1', '20000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d3')
 ORDER BY version_id DESC;
\echo '    ... and a stale fence starts nothing (expect UPDATE 0)'
EXECUTE c_round ('2026-09-07 00:00:00+00', 1);
\echo '--- the next round, on the grid after now: day 14 of the window (expect INSERT 0 1, then 2 | 14 days); and never a second waiting one (expect INSERT 0 0)'
EXECUTE w_schedule ('00000000-0000-0000-0000-00000000000a');
SELECT n, starts_at - (SELECT submissions_open_at FROM seasons WHERE id = '50000000-0000-0000-0000-0000000000e1') AS after_open
  FROM season_rounds WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND applied_at IS NULL;
EXECUTE w_schedule ('00000000-0000-0000-0000-00000000000a');

\echo '--- pair in round 1: every version wants the round''s 4 whatever its age (expect quota 4 for all three, rooms 4 each, room 12, round n 1)'
EXECUTE p_demand_doc ('50000000-0000-0000-0000-0000000000e1', 8, 2, 3.0, 64, 0.2) \gset
SELECT e ->> 'model_id' AS model_id, e ->> 'state' AS state, e ->> 'want' AS want, e ->> 'played' AS played
  FROM json_array_elements((:'body')::json -> 'wants') e ORDER BY 1;
SELECT r ->> 'model_id' AS model_id, r ->> 'room' AS room FROM json_array_elements((:'body')::json -> 'rooms') r ORDER BY 1;
SELECT (:'body')::json ->> 'room' AS room, (:'body')::json -> 'round' AS round, (:'body')::json -> 'limits' ->> 'strict_rooms' AS strict;
\echo '--- the insert stamps the round the match counts for (expect INSERT 0 2, then 901 | 1)'
SELECT epoch AS rep FROM clocks WHERE key = 'roster' \gset
EXECUTE p_insert (:rep, '50000000-0000-0000-0000-0000000000e1', 901, '70000000-0000-0000-0000-0000000000e1',
  '{20000000-0000-0000-0000-0000000000d2,10000000-0000-0000-0000-0000000000d3}', NULL, gen_random_uuid(), 5);
SELECT seed, round FROM matches WHERE seed = 901;
\echo '--- a rated round-1 game for dora and the wall: round_games counts it; the queued 901 is in flight for eve and the wall (expect dora 3 of 4, eve 3, wall 2 -- least-played first among equal wants)'
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders, status, played_at, rated_at, rated_seq, round)
VALUES ('11111111-1111-1111-1111-1111111111e1', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 'sha256:e1', 902,
        '70000000-0000-0000-0000-0000000000e1', 2, ARRAY['open']::ladder[], 'rated', now(), now(), 9001, 1);
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, rank, score, strikes) VALUES
  ('11111111-1111-1111-1111-1111111111e1', 0, '20000000-0000-0000-0000-0000000000d1', 'sha256:wd1', 'sha256:md1', 1, 5, 0),
  ('11111111-1111-1111-1111-1111111111e1', 1, '10000000-0000-0000-0000-0000000000d3', 'sha256:wd3', 'sha256:md3', 2, 1, 0);
SELECT version_id, games FROM round_games('50000000-0000-0000-0000-0000000000e1', 1) ORDER BY 1;
EXECUTE p_demand_doc ('50000000-0000-0000-0000-0000000000e1', 8, 2, 3.0, 64, 0.2) \gset
SELECT e ->> 'model_id' AS model_id, e ->> 'want' AS want, e ->> 'played' AS played
  FROM json_array_elements((:'body')::json -> 'wants') e;

\echo '--- the idle fill: off, no lanes are read (expect spare null); on at 10 games with mini-1''s lanes live, the target is 10, less what each has played and holds in the round (expect wall 8, dora 9, eve 9, and a spare number)'
SELECT (:'body')::json -> 'spare' AS spare_off;
EXECUTE f_set ('ants', 'rounds-2026', '{"enabled": true, "games": 10}', '00000000-0000-0000-0000-0000000000ad');
UPDATE runners SET plays_matches = true, last_seen_at = now() WHERE label = 'mini-1';
EXECUTE p_demand_doc ('50000000-0000-0000-0000-0000000000e1', 8, 2, 3.0, 64, 0.2) \gset
SELECT r ->> 'model_id' AS model_id, r ->> 'room' AS room FROM json_array_elements((:'body')::json -> 'rooms') r ORDER BY 1;
SELECT (:'body')::json -> 'spare' IS NOT NULL AS spare_read;
\echo '    ... a fill without games, or with a key it does not know, writes nothing (expect INSERT 0 0 twice)'
EXECUTE f_set ('ants', 'rounds-2026', '{"enabled": true}', '00000000-0000-0000-0000-0000000000ad');
EXECUTE f_set ('ants', 'rounds-2026', '{"enabled": false, "gmaes": 3}', '00000000-0000-0000-0000-0000000000ad');
\echo '    ... and a token exchange marks the role it reported, and NEITHER is the other''s negation (expect rd-match t/f, rd-admit f/t, rd-quiet f/f)'
EXECUTE g_register ('sha256:not-a-real-digest', 'rd-match', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', 3, 2400000, 1, NULL);
EXECUTE g_register ('sha256:not-a-real-digest', 'rd-admit', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', NULL, 2400000, 1, 1);
-- A runner that reports NEITHER lane is one from before either was reported. It must not be read as
-- an admitter, or an admin is told a queue is served by a machine that has never claimed anything.
EXECUTE g_register ('sha256:not-a-real-digest', 'rd-quiet', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', NULL, 2400000, 1, NULL);
SELECT label, plays_matches, admits FROM runners WHERE label LIKE 'rd-%' ORDER BY label;
\echo '    ... and both stick: an exchange that omits one says nothing about it rather than denying it (expect t, t)'
EXECUTE g_register ('sha256:not-a-real-digest', 'rd-match', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', NULL, 2400000, 1, 1);
SELECT plays_matches, admits FROM runners WHERE label = 'rd-match';
\echo '    ... a season key registers a runner for an admin of its season, and not for anyone else (expect INSERT 0 1, then INSERT 0 0)'
INSERT INTO runner_keys (id, user_id, label, key_hash, key_prefix, season_id) VALUES
  ('6b000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f1', 'cohort lab', 'sha256:season-key-of-its-admin', 'tbr_sk01', '50000000-0000-0000-0000-0000000000f1'),
  ('6b000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000f2', 'not theirs', 'sha256:season-key-of-a-stranger', 'tbr_sk02', '50000000-0000-0000-0000-0000000000f1');
EXECUTE g_register ('sha256:season-key-of-its-admin', 'cohort-1', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', 2, 2400000, 1, NULL);
EXECUTE g_register ('sha256:season-key-of-a-stranger', 'cohort-2', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', 2, 2400000, 1, NULL);

\echo '--- the countdown: round 2 moved to ten minutes from now is inside its fifteen-minute warning (expect UPDATE 1; one live public line naming the season, at = the start; then two bell rows, dora and eve, none for the wall)'
UPDATE season_rounds SET starts_at = now() + interval '10 minutes'
 WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND n = 2;
EXECUTE w_announce ('00000000-0000-0000-0000-00000000000a');
SELECT kind, body, at = (SELECT starts_at FROM season_rounds WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND n = 2) AS at_is_start,
       announcement_live(a) AS live, source
  FROM announcements a WHERE season_id = '50000000-0000-0000-0000-0000000000e1';
EXECUTE n_round ('00000000-0000-0000-0000-00000000000a');
SELECT u.handle, n.subject, n.data ->> 'games' AS games, n.dedupe_key LIKE 'round:%' AS keyed
  FROM notifications n JOIN users u ON u.id = n.user_id WHERE n.dedupe_key LIKE 'round:50000000-0000-0000-0000-0000000000e1%' ORDER BY 1;
\echo '    ... again: nothing twice (expect UPDATE 0, INSERT 0 0)'
EXECUTE w_announce ('00000000-0000-0000-0000-00000000000a');
EXECUTE n_round ('00000000-0000-0000-0000-00000000000a');

\echo '===== the finals, the admin''s ====='
\echo '--- while the window is open they are refused: round 2 waits, and the window is open (expect INSERT 0 0; waiting t, window_open t)'
EXECUTE r_create ('ants', 'rounds-2026', 'finals', NULL, 2, 4, 0.5, 5, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_create_why ('ants', 'rounds-2026', 'finals', NULL, 2, 4, 0.5, 5) \gset cw_
SELECT (:'cw_body')::json ->> 'waiting' AS waiting, (:'cw_body')::json ->> 'window_open' AS window_open;
\echo '--- the window closes; round 2 is cancelled by the admin, and its countdown ends with it (expect INSERT 0 1 audit; cancelled t; the line no longer live)'
UPDATE seasons SET submissions_close_at = now() - interval '1 minute', rules = rules || '{"closure": {"enabled": true, "policy": "finals"}}'
 WHERE id = '50000000-0000-0000-0000-0000000000e1';
EXECUTE r_update ('ants', 'rounds-2026', 2, NULL, NULL, NULL, NULL, NULL, true, '00000000-0000-0000-0000-0000000000ad');
SELECT cancelled_at IS NOT NULL AS cancelled FROM season_rounds WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND n = 2;
SELECT announcement_live(a) AS still_live FROM announcements a WHERE season_id = '50000000-0000-0000-0000-0000000000e1';
\echo '    ... a cancelled round takes nothing more (expect INSERT 0 0; cancelled t)'
EXECUTE r_update ('ants', 'rounds-2026', 2, NULL, 9, NULL, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_update_why ('ants', 'rounds-2026', 2, NULL, 9, NULL, NULL, NULL, NULL) \gset uw_
SELECT (:'uw_body')::json ->> 'cancelled' AS cancelled;
\echo '--- out-of-range numbers are refused and named (expect INSERT 0 0; valid f)'
EXECUTE r_create ('ants', 'rounds-2026', 'finals', NULL, 2.5, 4, 1.5, 5, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_create_why ('ants', 'rounds-2026', 'finals', NULL, 2.5, 4, 1.5, 5) \gset cv_
SELECT (:'cv_body')::json ->> 'valid' AS valid;
\echo '--- a submission still being admitted holds the finals back (expect INSERT 0 0; admitting 1), rolled back to a savepoint'
SAVEPOINT admitting;
INSERT INTO model_versions (model_id, game_id, season_id, version, status) VALUES
  ('e0000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 2, 'testing');
EXECUTE r_create ('ants', 'rounds-2026', 'finals', NULL, 2, 4, 0.5, 5, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_create_why ('ants', 'rounds-2026', 'finals', NULL, 2, 4, 0.5, 5) \gset ca_
SELECT (:'ca_body')::json ->> 'admitting' AS admitting;
ROLLBACK TO SAVEPOINT admitting;
\echo '--- the finals, starting now: 2 games each, sigma floor 4, mu halfway to the mean (expect INSERT 0 1 audit; then 3 | finals | 2)'
EXECUTE r_create ('ants', 'rounds-2026', 'finals', now(), 2, 4, 0.5, 5, '00000000-0000-0000-0000-0000000000ad');
SELECT n, kind, games FROM season_rounds WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND kind = 'finals';
\echo '    ... and nothing after them, of either kind (expect INSERT 0 0 twice)'
EXECUTE r_create ('ants', 'rounds-2026', 'round', NULL, 2, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_create ('ants', 'rounds-2026', 'finals', NULL, 3, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
\echo '--- count starts them: mean mu 29.33, so dora 29.67, eve 30.67, wall 27.67, every sigma 4; the queued 901 is cancelled ROUND_ENDED (expect UPDATE 1, the three ratings, then 901 cancelled ROUND_ENDED)'
EXECUTE c_round ('2026-09-08 00:00:00+00', 1);
SELECT version_id, round(mu::numeric, 2) AS mu, sigma FROM ratings
 WHERE version_id IN ('20000000-0000-0000-0000-0000000000d1', '20000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d3')
 ORDER BY version_id DESC;
SELECT seed, status, withdrawn_reason FROM matches WHERE seed = 901;
\echo '--- pair in the finals: the wall asks for nothing and has no wall of its own; the two entries want 2 behind a strict room (expect dora 2, eve 2 -- no wall row; rooms dora 2, eve 2; strict t; fill ignored, spare null)'
EXECUTE p_demand_doc ('50000000-0000-0000-0000-0000000000e1', 8, 2, 3.0, 64, 0.2) \gset
SELECT e ->> 'model_id' AS model_id, e ->> 'state' AS state, e ->> 'want' AS want FROM json_array_elements((:'body')::json -> 'wants') e ORDER BY 1;
SELECT r ->> 'model_id' AS model_id, r ->> 'room' AS room FROM json_array_elements((:'body')::json -> 'rooms') r ORDER BY 1;
SELECT (:'body')::json -> 'limits' ->> 'strict_rooms' AS strict, (:'body')::json -> 'spare' AS spare;
\echo '--- one finals game each: not done, and the season stays open whatever its policy says (expect entries 2, complete 0, done f; closed f)'
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders, status, played_at, rated_at, rated_seq, round)
VALUES ('11111111-1111-1111-1111-1111111111e2', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 'sha256:e1', 903,
        '70000000-0000-0000-0000-0000000000e1', 2, ARRAY['open']::ladder[], 'rated', now(), now(), 9002, 3);
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, rank, score, strikes) VALUES
  ('11111111-1111-1111-1111-1111111111e2', 0, '20000000-0000-0000-0000-0000000000d1', 'sha256:wd1', 'sha256:md1', 1, 5, 0),
  ('11111111-1111-1111-1111-1111111111e2', 1, '20000000-0000-0000-0000-0000000000d2', 'sha256:wd2', 'sha256:md2', 2, 1, 0);
SELECT entries, complete, done FROM season_finals('50000000-0000-0000-0000-0000000000e1');
EXECUTE w_close ('00000000-0000-0000-0000-00000000000a', 3.0, 8);
SELECT closed_at IS NOT NULL AS closed FROM seasons WHERE id = '50000000-0000-0000-0000-0000000000e1';
\echo '--- the leaderboard counts the round beside the season (expect round finals 2, each entry''s round_matches 1, the wall 0)'
EXECUTE x_leaderboard ('ants', 'open', 10, 0, 3.0, 'rounds-2026', NULL, NULL) \gset lb_
SELECT (:'lb_body')::json -> 'round' AS round;
SELECT e ->> 'model' AS model, e ->> 'round_matches' AS round_matches, e ->> 'matches' AS matches
  FROM json_array_elements((:'lb_body')::json -> 'entries') e ORDER BY 1;
\echo '--- the admin extends the running finals to 3 (expect INSERT 0 1); a start move on a started round is refused (expect INSERT 0 0; started t); back to 2'
EXECUTE r_update ('ants', 'rounds-2026', 3, NULL, 3, NULL, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_update ('ants', 'rounds-2026', 3, now() + interval '1 hour', NULL, NULL, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
EXECUTE r_update_why ('ants', 'rounds-2026', 3, now() + interval '1 hour', NULL, NULL, NULL, NULL, NULL) \gset us_
SELECT (:'us_body')::json ->> 'started' AS started;
EXECUTE r_update ('ants', 'rounds-2026', 3, NULL, 2, NULL, NULL, NULL, NULL, '00000000-0000-0000-0000-0000000000ad');
\echo '--- the second game each, with one match still running: done, but nothing folds after the podium, so the close waits (expect done t; closed f)'
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders, status, played_at, rated_at, rated_seq, round)
VALUES ('11111111-1111-1111-1111-1111111111e3', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 'sha256:e1', 904,
        '70000000-0000-0000-0000-0000000000e1', 2, ARRAY['open']::ladder[], 'rated', now(), now(), 9003, 3);
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, rank, score, strikes) VALUES
  ('11111111-1111-1111-1111-1111111111e3', 0, '20000000-0000-0000-0000-0000000000d1', 'sha256:wd1', 'sha256:md1', 2, 1, 0),
  ('11111111-1111-1111-1111-1111111111e3', 1, '20000000-0000-0000-0000-0000000000d2', 'sha256:wd2', 'sha256:md2', 1, 5, 0);
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders, status, claim_token, lease_expires_at, round)
VALUES ('11111111-1111-1111-1111-1111111111e4', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000e1', 'sha256:e1', 905,
        '70000000-0000-0000-0000-0000000000e1', 2, ARRAY['open']::ladder[], 'running', gen_random_uuid(), now() + interval '5 minutes', 3);
SELECT done FROM season_finals('50000000-0000-0000-0000-0000000000e1');
EXECUTE w_close ('00000000-0000-0000-0000-00000000000a', 3.0, 8);
SELECT closed_at IS NOT NULL AS closed FROM seasons WHERE id = '50000000-0000-0000-0000-0000000000e1';
\echo '--- it finishes and is rated: the close takes the season, the podium is frozen from the finals (expect closed t; open places 1 and 2, the two entries)'
UPDATE matches SET status = 'rated', played_at = now(), rated_at = now(), rated_seq = 9004 WHERE seed = 905;
EXECUTE w_close ('00000000-0000-0000-0000-00000000000a', 3.0, 8);
SELECT closed_at IS NOT NULL AS closed FROM seasons WHERE id = '50000000-0000-0000-0000-0000000000e1';
SELECT ladder, place FROM season_podium WHERE season_id = '50000000-0000-0000-0000-0000000000e1' AND ladder = 'open';
\echo '--- the admin''s rounds document reads it all back (expect state closed, policy finals, current 3, 3 rounds, finals done, 3 versions)'
EXECUTE r_doc ('ants', 'rounds-2026') \gset rd_
SELECT (:'rd_body')::json ->> 'state' AS state, (:'rd_body')::json ->> 'policy' AS policy,
       (:'rd_body')::json ->> 'current' AS current, json_array_length((:'rd_body')::json -> 'rounds') AS rounds,
       (:'rd_body')::json -> 'finals' ->> 'done' AS done, json_array_length((:'rd_body')::json -> 'versions') AS versions;
ROLLBACK;

\echo '===== private seasons: the public reads answer nothing, a viewer who may see one reads it ====='
-- The private cohort 50..f1 holds fencer's rated, listed match f9 and version f9. A session for the
-- platform admin (ops) and one for a stranger (dora of the rounds scenario is gone, so a new one).
BEGIN;
INSERT INTO users (id, handle, role) VALUES ('00000000-0000-0000-0000-0000000000e9', 'cohort-outsider', 'competitor');
INSERT INTO sessions (sid, user_id, expires_at) VALUES
  ('5e000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000ad', now() + interval '1 day'),
  ('5e000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e9', now() + interval '1 day');
SELECT slug AS cohort_slug FROM seasons WHERE id = '50000000-0000-0000-0000-0000000000f1' \gset
\echo '--- a private match by id: the public (no session) and a stranger get 0 rows; the platform admin gets it (expect 0, 0, 1)'
EXECUTE x_match ('11111111-1111-1111-1111-1111111111f9', NULL, NULL);
EXECUTE x_match ('11111111-1111-1111-1111-1111111111f9', '00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2');
EXECUTE x_match ('11111111-1111-1111-1111-1111111111f9', '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1');
\echo '--- a private version by id, the same three (expect 0, 0, 1)'
EXECUTE v_public ('20000000-0000-0000-0000-0000000000f9', 2.0, NULL, NULL);
EXECUTE v_public ('20000000-0000-0000-0000-0000000000f9', 2.0, '00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2');
EXECUTE v_public ('20000000-0000-0000-0000-0000000000f9', 2.0, '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1');
\echo '--- the season list: the private cohort is in the admin''s and nobody else''s (expect f, f, t)'
EXECUTE x_seasons ('ants', NULL, NULL) \gset sl0_
SELECT position(:'cohort_slug' in :'sl0_body') > 0 AS public_sees;
EXECUTE x_seasons ('ants', '00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2') \gset sl1_
SELECT position(:'cohort_slug' in :'sl1_body') > 0 AS stranger_sees;
EXECUTE x_seasons ('ants', '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1') \gset sl2_
SELECT position(:'cohort_slug' in :'sl2_body') > 0 AS admin_sees;
\echo '--- playing on the private slug: the public gets no row, the admin a count (expect 0 rows, then 1 row)'
EXECUTE x_playing ('ants', :'cohort_slug', NULL, NULL);
EXECUTE x_playing ('ants', :'cohort_slug', '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1');
\echo '--- the private match''s thread (BRD Q8): the public and a stranger find no host, the admin does (expect f, f, t)'
EXECUTE cm_threads ('11111111-1111-1111-1111-1111111111f9', NULL, NULL, NULL, NULL) \gset th0_
EXECUTE cm_threads ('11111111-1111-1111-1111-1111111111f9', NULL, NULL, '00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2') \gset th1_
EXECUTE cm_threads ('11111111-1111-1111-1111-1111111111f9', NULL, NULL, '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1') \gset th2_
SELECT :'th0_found' AS public_found, :'th1_found' AS stranger_found, :'th2_found' AS admin_found;
\echo '--- a stranger makes no thread on it and posts nothing (expect INSERT 0 0 twice); the admin makes it and posts (expect INSERT 0 1 twice); then the stranger still posts nothing into the thread that now exists (expect INSERT 0 0)'
EXECUTE cm_thread ('00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-1111111111f9', NULL);
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-1111111111f9', NULL, NULL, 'let me in', 'c0000000-0000-0000-0000-0000000000f1');
EXECUTE cm_thread ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-1111111111f9', NULL);
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-1111111111f9', NULL, NULL, 'good game', 'c0000000-0000-0000-0000-0000000000f2');
EXECUTE cm_post ('00000000-0000-0000-0000-0000000000e9', '5e000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-1111111111f9', NULL, NULL, 'let me in', 'c0000000-0000-0000-0000-0000000000f3');
\echo '--- a revoked session reads as the public (expect 0)'
UPDATE sessions SET revoked_at = now() WHERE sid = '5e000000-0000-0000-0000-0000000000f1';
EXECUTE x_match ('11111111-1111-1111-1111-1111111111f9', '00000000-0000-0000-0000-0000000000ad', '5e000000-0000-0000-0000-0000000000f1');
ROLLBACK;

\echo '===== the migration: boards and baselines imported, an entry re-entered, and who may enter ====='
BEGIN;
-- A closed season with two boards, one baseline in play and dora's entry standing; a new open one.
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, closed_at) VALUES
  ('50000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000000a', 21, 'Import Src', 'import-src', 'sha256:e1', now() - interval '20 days', now() - interval '10 days', now() - interval '9 days'),
  ('50000000-0000-0000-0000-00000000aa02', '00000000-0000-0000-0000-00000000000a', 22, 'Import Dst', 'import-dst', 'sha256:e1', now() - interval '1 day', now() + interval '20 days', NULL);
INSERT INTO users (id, handle, role) VALUES
  ('00000000-0000-0000-0000-00000000aa0d', 'mig-dora', 'competitor'),
  ('00000000-0000-0000-0000-00000000aa0e', 'mig-erin', 'competitor'),
  ('00000000-0000-0000-0000-00000000aa0b', 'baseline.mig-wall', 'baseline');
INSERT INTO identities (user_id, provider, subject, login) VALUES
  ('00000000-0000-0000-0000-00000000aa0d', 'github', 'mig-d', 'mig-dora'),
  ('00000000-0000-0000-0000-00000000aa0e', 'github', 'mig-e', 'mig-erin');
INSERT INTO sessions (sid, user_id, expires_at) VALUES
  ('5e000000-0000-0000-0000-00000000aa0d', '00000000-0000-0000-0000-00000000aa0d', now() + interval '1 day'),
  ('5e000000-0000-0000-0000-00000000aa0e', '00000000-0000-0000-0000-00000000aa0e', now() + interval '1 day');
INSERT INTO models (id, owner_id, game_id, name) VALUES
  ('e0000000-0000-0000-0000-00000000aa0d', '00000000-0000-0000-0000-00000000aa0d', '00000000-0000-0000-0000-00000000000a', 'mig entry'),
  ('e0000000-0000-0000-0000-00000000aa0e', '00000000-0000-0000-0000-00000000aa0e', '00000000-0000-0000-0000-00000000000a', 'erin entry'),
  ('e0000000-0000-0000-0000-00000000aa0b', '00000000-0000-0000-0000-00000000aa0b', '00000000-0000-0000-0000-00000000000a', 'mig wall');
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('20000000-0000-0000-0000-00000000aa0d', 'e0000000-0000-0000-0000-00000000aa0d', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000aa01', 1, 'active', 'nano', 'sha256:' || repeat('d', 64), 'sha256:' || repeat('1', 64), '1.8.1'),
  ('20000000-0000-0000-0000-00000000aa0e', 'e0000000-0000-0000-0000-00000000aa0e', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000aa01', 1, 'active', 'nano', 'sha256:' || repeat('e', 64), 'sha256:' || repeat('2', 64), '1.8.1'),
  ('10000000-0000-0000-0000-00000000aa0b', 'e0000000-0000-0000-0000-00000000aa0b', '00000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000aa01', 1, 'disabled', 'nano', 'sha256:' || repeat('b', 64), 'sha256:' || repeat('3', 64), '1.8.1');
INSERT INTO season_maps (season_id, map_id, players, rows, cols, digest, board, enabled, added_by) VALUES
  ('50000000-0000-0000-0000-00000000aa01', 'small-open-2p-1h', 2, 24, 24, 'sha256:m1', '{"id": "small-open-2p-1h"}', true, '00000000-0000-0000-0000-0000000000ad'),
  ('50000000-0000-0000-0000-00000000aa01', 'small-cave-2p-1h', 2, 24, 24, 'sha256:m2', '{"id": "small-cave-2p-1h"}', true, '00000000-0000-0000-0000-0000000000ad');
\echo '--- a maps list that is not an array imports nothing (expect INSERT 0 0); a named board alone (expect INSERT 0 1)'
EXECUTE m_import ('ants', 'import-dst', 'import-src', '{"maps": "small-open-2p-1h"}', '00000000-0000-0000-0000-0000000000ad');
EXECUTE m_import ('ants', 'import-dst', 'import-src', '{"maps": ["small-open-2p-1h"]}', '00000000-0000-0000-0000-0000000000ad');
\echo '--- boards imported, switched off, once (expect INSERT 0 1, the other, then two rows enabled f, then INSERT 0 0); from an unknown season nothing (expect INSERT 0 0)'
EXECUTE m_import ('ants', 'import-dst', 'import-src', NULL, '00000000-0000-0000-0000-0000000000ad');
SELECT map_id, enabled FROM season_maps WHERE season_id = '50000000-0000-0000-0000-00000000aa02' ORDER BY map_id;
EXECUTE m_import ('ants', 'import-dst', 'import-src', NULL, '00000000-0000-0000-0000-0000000000ad');
EXECUTE m_import ('ants', 'import-dst', 'no-such', NULL, '00000000-0000-0000-0000-0000000000ad');
\echo '--- a baselines list that is not an array imports nothing (expect INSERT 0 0)'
EXECUTE b_import ('ants', 'import-dst', 'import-src', '{"baselines": {"mig wall": true}}', '00000000-0000-0000-0000-0000000000ad');
\echo '--- the baseline imported over the same bytes, testing (expect INSERT 0 1, then testing | t), once (expect INSERT 0 0)'
EXECUTE b_import ('ants', 'import-dst', 'import-src', NULL, '00000000-0000-0000-0000-0000000000ad');
SELECT v.status, v.artifact_key = 'models/10000000-0000-0000-0000-00000000aa0b/model.onnx' AS same_bytes
  FROM model_versions v WHERE v.model_id = 'e0000000-0000-0000-0000-00000000aa0b' AND v.season_id = '50000000-0000-0000-0000-00000000aa02';
EXECUTE b_import ('ants', 'import-dst', 'import-src', NULL, '00000000-0000-0000-0000-00000000aa0d');
\echo '--- the season audit carries the imports (expect 3 lines with the season stamped)'
SELECT count(*) AS stamped FROM audit_log WHERE season_id = '50000000-0000-0000-0000-00000000aa02' AND action IN ('map.import', 'baseline.import');
EXECUTE sa_audit ('50000000-0000-0000-0000-00000000aa02', 'map.', NULL) \gset au_
SELECT json_array_length((:'au_body')::json -> 'entries') AS map_lines;
\echo '--- re-entry: dora''s standing in import-src, entered into import-dst over its own bytes (expect the source, INSERT 0 1, same bytes t)'
EXECUTE r_source ('ants', 'e0000000-0000-0000-0000-00000000aa0d', 'import-src', '00000000-0000-0000-0000-00000000aa0d', '5e000000-0000-0000-0000-00000000aa0d') \gset rs_
SELECT (:'rs_body')::json ->> 'version_id' AS source_version;
EXECUTE s_insert ('00000000-0000-0000-0000-00000000aa0d', 'ants', 'e0000000-0000-0000-0000-00000000aa0d', '5e000000-0000-0000-0000-00000000aa0d', 'sha256:' || repeat('d', 64), 'sha256:' || repeat('1', 64), NULL, 'import-dst', '20000000-0000-0000-0000-00000000aa0d');
SELECT artifact_key = 'models/20000000-0000-0000-0000-00000000aa0d/model.onnx' AS same_bytes FROM model_versions
 WHERE model_id = 'e0000000-0000-0000-0000-00000000aa0d' AND season_id = '50000000-0000-0000-0000-00000000aa02';
\echo '    ... erin cannot borrow dora''s bytes, whatever id she names (expect INSERT 0 0)'
EXECUTE s_insert ('00000000-0000-0000-0000-00000000aa0e', 'ants', 'e0000000-0000-0000-0000-00000000aa0e', '5e000000-0000-0000-0000-00000000aa0e', 'sha256:' || repeat('d', 64), 'sha256:' || repeat('1', 64), NULL, 'import-dst', '20000000-0000-0000-0000-00000000aa0d');
\echo '--- S5: erin made a season admin of import-dst may not enter it (expect f, then INSERT 0 0)'
INSERT INTO season_admins (season_id, user_id, added_by) VALUES ('50000000-0000-0000-0000-00000000aa02', '00000000-0000-0000-0000-00000000aa0e', '00000000-0000-0000-0000-0000000000ad');
SELECT season_admits(s, '00000000-0000-0000-0000-00000000aa0e') AS erin_admitted FROM seasons s WHERE s.id = '50000000-0000-0000-0000-00000000aa02';
EXECUTE s_insert ('00000000-0000-0000-0000-00000000aa0e', 'ants', 'e0000000-0000-0000-0000-00000000aa0e', '5e000000-0000-0000-0000-00000000aa0e', 'sha256:' || repeat('e', 64), 'sha256:' || repeat('2', 64), NULL, 'import-dst', NULL);
\echo '--- S3: an invite for a login nobody has yet stays a login; its first sign-in pins it (expect INSERT 0 1 twice, null, UPDATE 1, pinned t); a second account later holding the login is not admitted by it (expect f)'
UPDATE seasons SET entry = 'restricted' WHERE id = '50000000-0000-0000-0000-00000000aa02';
EXECUTE p_add ('50000000-0000-0000-0000-00000000aa02', 'github', '["mig-newbie"]', '00000000-0000-0000-0000-0000000000ad');
SELECT user_id FROM season_participants WHERE season_id = '50000000-0000-0000-0000-00000000aa02' AND login = 'mig-newbie';
INSERT INTO users (id, handle) VALUES ('00000000-0000-0000-0000-00000000aa0f', 'mig-newbie');
INSERT INTO identities (user_id, provider, subject, login) VALUES ('00000000-0000-0000-0000-00000000aa0f', 'github', 'mig-n', 'mig-newbie');
EXECUTE a_pin ('github', 'mig-n', 'mig-newbie');
SELECT user_id = '00000000-0000-0000-0000-00000000aa0f' AS pinned FROM season_participants WHERE season_id = '50000000-0000-0000-0000-00000000aa02' AND login = 'mig-newbie';
INSERT INTO users (id, handle) VALUES ('00000000-0000-0000-0000-00000000aa10', 'mig-other');
INSERT INTO identities (user_id, provider, subject, login) VALUES ('00000000-0000-0000-0000-00000000aa10', 'github', 'mig-o', 'MIG-NEWBIE');
SELECT season_admits(s, '00000000-0000-0000-0000-00000000aa10') AS other_admitted FROM seasons s WHERE s.id = '50000000-0000-0000-0000-00000000aa02';
\echo '--- S8: a participant added pinned is told (expect INSERT 0 1 for the add, then INSERT 0 2: mig-dora, and mig-newbie whose invite was pinned at sign-in this minute -- each once, keyed on the row)'
EXECUTE p_add ('50000000-0000-0000-0000-00000000aa02', 'github', '["mig-dora"]', '00000000-0000-0000-0000-0000000000ad');
EXECUTE p_notify ('50000000-0000-0000-0000-00000000aa02');
\echo '--- S8: the season''s send reaches its people -- mig-dora (entered, and a pinned participant), mig-newbie (pinned), erin (its admin): 3 people, baselines never (expect recipients 3, INSERT 0 1, then 1 send)'
EXECUTE n_season_doc ('50000000-0000-0000-0000-00000000aa02', 'ants', 'import-dst') \gset nd_
SELECT (:'nd_body')::json ->> 'recipients' AS recipients;
EXECUTE n_season_send ('00000000-0000-0000-0000-00000000aa0e', '5e000000-0000-0000-0000-00000000aa0e', 'b0000000-0000-0000-0000-00000000aa01', 'Boards are up', '/maps', '50000000-0000-0000-0000-00000000aa02', 'ants', 'import-dst');
EXECUTE n_season_doc ('50000000-0000-0000-0000-00000000aa02', 'ants', 'import-dst') \gset nd2_
SELECT json_array_length((:'nd2_body')::json -> 'sends') AS sends;
ROLLBACK;

\echo '===== the fleet fence: which runner may claim which season, and whether anything can admit ====='
-- S10. The fleet policy decides who plays and who admits, and until now it was proven only against a
-- running stack with real runner containers -- so nothing offline caught a regression in it.
-- check-sql.sh proves GRANTS, not PREDICATES: `runner_gate` holding SELECT on seasons.fleet says
-- nothing about the CASE that reads it. Every assertion below is the shipped claim, executed as the
-- role the gate connects as, and each negative must stay negative.
--
-- The matrix (BRD R4), for one season, by its fleet policy:
--        own       -> its own runners claim it;  a platform runner claims nothing of it
--        platform  -> its own runners claim it NOT; a platform runner does
--        both      -> either
-- and, whatever any season says, A SEASON RUNNER NEVER REACHES ANOTHER SEASON.
BEGIN;
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, fleet) VALUES
  ('5f000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 901, 'Fleet A', 'fleet-a', 'sha256:e1',
   now() - interval '1 hour', now() + interval '1 day', '{"matches": "own", "admissions": "own"}'),
  ('5f000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 902, 'Fleet B', 'fleet-b', 'sha256:e1',
   now() - interval '1 hour', now() + interval '1 day', '{"matches": "platform", "admissions": "platform"}');
INSERT INTO season_maps (id, season_id, map_id, players, rows, cols, digest, board, enabled, added_by) VALUES
  ('7f000000-0000-0000-0000-000000000001', '5f000000-0000-0000-0000-000000000001', 'fa', 2, 24, 24, 'sha256:fa', '{"id": "fa"}', true, '00000000-0000-0000-0000-0000000000ad'),
  ('7f000000-0000-0000-0000-000000000002', '5f000000-0000-0000-0000-000000000002', 'fb', 2, 24, 24, 'sha256:fb', '{"id": "fb"}', true, '00000000-0000-0000-0000-0000000000ad');
-- A key bound to Fleet A, owned by the platform admin (live_runner_keys passes a season key of a
-- platform admin as well as of a season admin), and the platform key the seed already made.
INSERT INTO runner_keys (id, user_id, label, key_hash, key_prefix, season_id)
VALUES ('6f000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000ad', 'fleet A lab',
        'sha256:fleet-a-season-key', 'tbr_fa01', '5f000000-0000-0000-0000-000000000001');
\echo '--- four machines register themselves, two per fleet, one of each role (expect INSERT 0 1 x4)'
EXECUTE g_register ('sha256:not-a-real-digest',    'fl-plat-match', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', 4,    2400000, 2, NULL);
EXECUTE g_register ('sha256:not-a-real-digest',    'fl-plat-admit', 'sha256:e1', 'x', '1.11.1', 1, 'arm64', NULL, 2400000, 1, 1);
EXECUTE g_register ('sha256:fleet-a-season-key',   'fl-own-match',  'sha256:e1', 'x', '1.11.1', 1, 'arm64', 4,    2400000, 2, NULL);
EXECUTE g_register ('sha256:fleet-a-season-key',   'fl-own-admit',  'sha256:e1', 'x', '1.11.1', 1, 'arm64', NULL, 2400000, 1, 1);
SELECT id AS fl_pm FROM runners WHERE label = 'fl-plat-match' \gset
SELECT id AS fl_pa FROM runners WHERE label = 'fl-plat-admit' \gset
SELECT id AS fl_om FROM runners WHERE label = 'fl-own-match' \gset
SELECT id AS fl_oa FROM runners WHERE label = 'fl-own-admit' \gset
-- One pending match in each season, re-pended before every claim so each assertion is independent.
INSERT INTO matches (id, game_id, season_id, status, engine_digest, seed, season_map_id, seat_count, ladders) VALUES
  ('1f000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '5f000000-0000-0000-0000-000000000001', 'pending', 'sha256:e1', 1, '7f000000-0000-0000-0000-000000000001', 2, ARRAY['open']::ladder[]),
  ('1f000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '5f000000-0000-0000-0000-000000000002', 'pending', 'sha256:e1', 2, '7f000000-0000-0000-0000-000000000002', 2, ARRAY['open']::ladder[]);

\echo '--- MATCHES, Fleet A = own: its own runner takes its row, the platform runner takes nothing (expect UPDATE 1, UPDATE 0)'
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000001', 60, 4, :'fl_om', 1000, 1000, 5);
RESET ROLE;
UPDATE matches SET status = 'pending', claim_token = NULL, played_by = NULL, lease_expires_at = NULL WHERE id = '1f000000-0000-0000-0000-000000000001';
-- Fleet B is 'platform', so the platform runner WOULD reach it: park B's row on another engine
-- (the claim matches m.engine_digest against what the runner reported) so an answer of 1 below can
-- only have come from A. Parking by status would have to satisfy matches_status_shape.
UPDATE matches SET engine_digest = 'sha256:parked' WHERE id = '1f000000-0000-0000-0000-000000000002';
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000002', 60, 4, :'fl_pm', 1000, 1000, 5);
RESET ROLE;

\echo '--- MATCHES, Fleet A = platform: the same two the other way round (expect UPDATE 0, UPDATE 1)'
UPDATE seasons SET fleet = '{"matches": "platform", "admissions": "platform"}' WHERE id = '5f000000-0000-0000-0000-000000000001';
UPDATE matches SET status = 'pending', claim_token = NULL, played_by = NULL, lease_expires_at = NULL WHERE id = '1f000000-0000-0000-0000-000000000001';
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000003', 60, 4, :'fl_om', 1000, 1000, 5);
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000004', 60, 4, :'fl_pm', 1000, 1000, 5);
RESET ROLE;

\echo '--- MATCHES, Fleet A = both: either machine, whichever asks first (expect UPDATE 1, then UPDATE 0 -- the row is gone, not refused)'
UPDATE seasons SET fleet = '{"matches": "both", "admissions": "both"}' WHERE id = '5f000000-0000-0000-0000-000000000001';
UPDATE matches SET status = 'pending', claim_token = NULL, played_by = NULL, lease_expires_at = NULL WHERE id = '1f000000-0000-0000-0000-000000000001';
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000005', 60, 4, :'fl_om', 1000, 1000, 5);
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000006', 60, 4, :'fl_pm', 1000, 1000, 5);
RESET ROLE;

\echo '--- MATCHES: a season runner never reaches ANOTHER season, whatever that season says (expect UPDATE 0 on both `platform` and `both`)'
-- Fleet A's runner, offered only Fleet B's row. This is the property the BRD's trust argument rests
-- on: it is what makes handing a runner key to a university acceptable.
UPDATE matches SET engine_digest = 'sha256:parked' WHERE id = '1f000000-0000-0000-0000-000000000001';
UPDATE matches SET engine_digest = 'sha256:e1', status = 'pending', claim_token = NULL, played_by = NULL, lease_expires_at = NULL WHERE id = '1f000000-0000-0000-0000-000000000002';
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000007', 60, 4, :'fl_om', 1000, 1000, 5);
RESET ROLE;
UPDATE seasons SET fleet = '{"matches": "both", "admissions": "both"}' WHERE id = '5f000000-0000-0000-0000-000000000002';
SET ROLE runner_gate;
EXECUTE k_claim ('sha256:e1', '3f000000-0000-0000-0000-000000000008', 60, 4, :'fl_om', 1000, 1000, 5);
RESET ROLE;
UPDATE seasons SET fleet = '{"matches": "platform", "admissions": "platform"}' WHERE id = '5f000000-0000-0000-0000-000000000002';

\echo '--- ADMISSIONS take the same predicate on the VERSION''s season: one queued in each (expect INSERT 0 2)'
INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class, weights_hash, manifest_hash, orion_version) VALUES
  ('2f000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '5f000000-0000-0000-0000-000000000001', 901, 'testing', 'nano', 'sha256:wfa', 'sha256:mfa', '1.11.1'),
  ('2f000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', '5f000000-0000-0000-0000-000000000002', 902, 'testing', 'nano', 'sha256:wfb', 'sha256:mfb', '1.11.1');
INSERT INTO admissions (version_id, registration, manifest, artifact_bytes, budget_ops) VALUES
  ('2f000000-0000-0000-0000-000000000001', '{}', '{}', 1024, 1000000),
  ('2f000000-0000-0000-0000-000000000002', '{}', '{}', 1024, 1000000);
\echo '    Fleet A = own (B stays platform): its own admitter takes A''s row, the platform admitter takes only B''s (expect UPDATE 1, UPDATE 1, and the seasons they took)'
UPDATE seasons SET fleet = '{"matches": "own", "admissions": "own"}' WHERE id = '5f000000-0000-0000-0000-000000000001';
SET ROLE runner_gate;
EXECUTE g_admit_claim (:'fl_oa', '0f000000-0000-0000-0000-000000000001', 300, 3);
EXECUTE g_admit_claim (:'fl_pa', '0f000000-0000-0000-0000-000000000002', 300, 3);
RESET ROLE;
SELECT v.season_id = '5f000000-0000-0000-0000-000000000001' AS own_took_a
  FROM admissions a JOIN model_versions v ON v.id = a.version_id WHERE a.claim_token = '0f000000-0000-0000-0000-000000000001';
SELECT v.season_id = '5f000000-0000-0000-0000-000000000002' AS platform_took_b
  FROM admissions a JOIN model_versions v ON v.id = a.version_id WHERE a.claim_token = '0f000000-0000-0000-0000-000000000002';
\echo '    the platform admitter is refused A''s row even with nothing else waiting (expect UPDATE 0)'
UPDATE admissions SET runner_id = NULL, claim_token = NULL, lease_expires_at = NULL, attempts = 0 WHERE version_id = '2f000000-0000-0000-0000-000000000001';
DELETE FROM admissions WHERE version_id = '2f000000-0000-0000-0000-000000000002';
SET ROLE runner_gate;
EXECUTE g_admit_claim (:'fl_pa', '0f000000-0000-0000-0000-000000000003', 300, 3);
RESET ROLE;

\echo '--- S9: admitters_up() is the SAME reach, so the count and the claim cannot disagree (expect A 1/own, then 0 when its machine goes quiet, then 1 again under `both`)'
SELECT admitters_up('5f000000-0000-0000-0000-000000000001') AS a_own,
       admitters_up('5f000000-0000-0000-0000-000000000002') AS b_platform;
\echo '    a machine silent for two minutes is down, whatever live_runners says about its key (expect 0, and live still t)'
UPDATE runners SET last_seen_at = now() - interval '2 minutes' WHERE id = :'fl_oa';
SELECT admitters_up('5f000000-0000-0000-0000-000000000001') AS a_quiet,
       EXISTS (SELECT 1 FROM live_runners lr WHERE lr.id = :'fl_oa') AS still_authorised;
\echo '    and the claim agrees with the count it disagreed with before: nothing (expect UPDATE 0)'
SET ROLE runner_gate;
EXECUTE g_admit_claim (:'fl_pa', '0f000000-0000-0000-0000-000000000004', 300, 3);
RESET ROLE;
\echo '    under `both` the platform''s machine serves A, so the queue is not stuck after all (expect 1)'
UPDATE seasons SET fleet = '{"matches": "both", "admissions": "both"}' WHERE id = '5f000000-0000-0000-0000-000000000001';
SELECT admitters_up('5f000000-0000-0000-0000-000000000001') AS a_both;
\echo '    a MATCH runner is not an admitter, and a machine that reported neither lane is neither (expect 1, not 3)'
SELECT admitters_up('5f000000-0000-0000-0000-000000000001') AS still_one;
\echo '    platform-wide, one machine reaching two seasons is one machine (expect 1)'
SELECT admitters_up() AS platform_wide;
\echo '    a revoked key takes its machines out of the count with no other change (expect 0)'
UPDATE runner_keys SET revoked_at = now() WHERE id = 'c0000000-0000-0000-0000-000000000001';
SELECT admitters_up('5f000000-0000-0000-0000-000000000001') AS after_revoke;

\echo '--- W8: the two documents that draw the alarm say the same thing (expect the season stuck: queued 1, admitters 0, reach both; and the platform queue with no admitter)'
-- The season desk reads its own document; /v1/status reads the platform's. Both take the number
-- from admitters_up(), so neither can tell an admin a queue is served when the claim would refuse.
EXECUTE sk_keys ('5f000000-0000-0000-0000-000000000001') \gset sk_
SELECT (:'sk_body')::json -> 'admissions' ->> 'queued'    AS queued,
       (:'sk_body')::json -> 'admissions' ->> 'admitters' AS admitters,
       (:'sk_body')::json -> 'admissions' ->> 'reach'     AS reach,
       json_array_length((:'sk_body')::json -> 'keys')    AS keys;
EXECUTE x_status \gset st_
SELECT (:'st_body')::json -> 'arena' ->> 'admission_queue' AS platform_queue,
       (:'st_body')::json -> 'arena' ->> 'admitters'       AS platform_admitters;
\echo '    and a machine calling in again clears both (expect admitters 1, platform 1)'
UPDATE runner_keys SET revoked_at = NULL WHERE id = 'c0000000-0000-0000-0000-000000000001';
UPDATE runners SET last_seen_at = now() WHERE label = 'fl-plat-admit';
EXECUTE sk_keys ('5f000000-0000-0000-0000-000000000001') \gset sk2_
SELECT (:'sk2_body')::json -> 'admissions' ->> 'admitters' AS admitters;
EXECUTE x_status \gset st2_
SELECT (:'st2_body')::json -> 'arena' ->> 'admitters' AS platform_admitters;
ROLLBACK;

\echo '===== entry narrows one way, before the open, and never on a private season (BRD Q4) ====='
-- S11. Entry and visibility are set at creation and this is the one change either may take
-- afterwards. Every half of the rule is a predicate in the write, not a guard, so none of it can be
-- raced by a caller arriving as a season opens -- and a private season needs no clause of its own:
-- the table CHECK holds private to restricted, so `entry = 'open'` is false for it and the write
-- finds nothing. Each refusal below must stay a refusal.
BEGIN;
INSERT INTO seasons (id, game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at, visibility, entry) VALUES
  ('5e100000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 911, 'Entry Sched', 'entry-sched', 'sha256:e1',
   now() + interval '1 day', now() + interval '8 days', 'public', 'open'),
  ('5e100000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 912, 'Entry Open', 'entry-open', 'sha256:e1',
   now() - interval '1 hour', now() + interval '8 days', 'public', 'open'),
  ('5e100000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000a', 913, 'Entry Priv', 'entry-priv', 'sha256:e1',
   now() + interval '1 day', now() + interval '8 days', 'private', 'restricted');
\echo '--- a scheduled public season narrows, once, and the audit line is the same statement (expect INSERT 0 1; restricted; 1 line)'
EXECUTE se_entry ('ants', 'entry-sched', 'restricted', '00000000-0000-0000-0000-0000000000ad');
SELECT entry FROM seasons WHERE slug = 'entry-sched';
SELECT count(*) AS audit_lines FROM audit_log WHERE action = 'season.entry' AND target_id = 'entry-sched';
\echo '    ... and not twice: restricted is where it stops (expect INSERT 0 0)'
EXECUTE se_entry ('ants', 'entry-sched', 'restricted', '00000000-0000-0000-0000-0000000000ad');
\echo '    ... nor back to open, which would publish a cohort''s season (expect INSERT 0 0; still restricted)'
EXECUTE se_entry ('ants', 'entry-sched', 'open', '00000000-0000-0000-0000-0000000000ad');
SELECT entry FROM seasons WHERE slug = 'entry-sched';
\echo '--- an OPEN season does not narrow: competitors have submitted under the entry they read (expect INSERT 0 0; still open)'
EXECUTE se_entry ('ants', 'entry-open', 'restricted', '00000000-0000-0000-0000-0000000000ad');
SELECT entry FROM seasons WHERE slug = 'entry-open';
\echo '--- a PRIVATE season is already restricted, so there is nothing to narrow and visibility stays fixed (expect INSERT 0 0; private/restricted)'
EXECUTE se_entry ('ants', 'entry-priv', 'restricted', '00000000-0000-0000-0000-0000000000ad');
SELECT visibility, entry FROM seasons WHERE slug = 'entry-priv';
\echo '--- an unknown season and a value that is not `restricted` write nothing (expect INSERT 0 0 twice)'
EXECUTE se_entry ('ants', 'no-such-season', 'restricted', '00000000-0000-0000-0000-0000000000ad');
EXECUTE se_entry ('ants', 'entry-sched', 'public', '00000000-0000-0000-0000-0000000000ad');
\echo '--- what narrowing MEANS: an empty roster admits nobody, which is the point of narrowing before filling it (expect f, then t once listed)'
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS alice_admitted FROM seasons s WHERE s.slug = 'entry-sched';
INSERT INTO season_participants (season_id, provider, login, user_id, added_by)
VALUES ('5e100000-0000-0000-0000-000000000001', 'github', 'alice', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000ad');
SELECT season_admits(s, '00000000-0000-0000-0000-0000000000a1') AS alice_admitted FROM seasons s WHERE s.slug = 'entry-sched';
ROLLBACK;
