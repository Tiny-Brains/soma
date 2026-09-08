-- Race 2, holder: the live occurrence (10:01/1) folds row 52 inside a transaction it keeps open
-- for 4 s, so its FOR SHARE on the fence row is held when the newer claim arrives.
\set ON_ERROR_STOP on
\pset footer off
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
\echo 'holder: folding row 52 under the live fence 10:01/1 and holding the transaction open (expect UPDATE 4)'
BEGIN;
EXECUTE c_fold ('2026-09-07 10:01:00+00', 1, :'m52',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000002","ladder":"nano","mu":31,"sigma":6},{"seat":0,"model_id":"20000000-0000-0000-0000-000000000002","ladder":"open","mu":32,"sigma":5.5},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"nano","mu":26,"sigma":5.5},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":25.5,"sigma":5.6}]');
SELECT pg_sleep(4);
COMMIT;
\echo 'holder: committed; v2 now has seq 0 (seed) and seq 1 on both ladders; chain audit (expect 0 rows)'
SELECT ladder, seq, mu_before, mu_after FROM rating_events WHERE model_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder, seq;
EXECUTE a_chain;
