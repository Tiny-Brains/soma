-- Race 1, holder: a newer count occurrence claims the fence and stays uncommitted for 4 s.
-- Setup first: claim, start and finish row 52 so the prober has something to fold.
\set ON_ERROR_STOP on
\pset footer off
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
EXECUTE k_claim ('sha256:e2', '{}', 8, '30000000-0000-0000-0000-000000000006', 60);
EXECUTE k_start ('30000000-0000-0000-0000-000000000006', ARRAY[:'m52'::uuid]);
EXECUTE k_finish ('30000000-0000-0000-0000-000000000006', :'m52',
  '[{"seat":0,"rank":1,"score":9,"strikes":0},{"seat":1,"rank":2,"score":4,"strikes":0}]',
  'all_food', 100, 3000, 'sha256:e2', 'sha256:ev1', 'replays/ants/z/t6.json');
\echo 'holder: row 52 finished; claiming fence 10:01/1 and holding the transaction open'
BEGIN;
EXECUTE c_fence ('2026-09-07 10:01:00+00', 1);
SELECT pg_sleep(4);
COMMIT;
\echo 'holder: committed'
