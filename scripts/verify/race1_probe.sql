-- Race 1, prober: the stale occurrence (10:00/2) folds row 52 while the newer claim is uncommitted.
-- Expected: the FOR SHARE blocks behind the claim's row lock, then sees the new fence: UPDATE 0,
-- row 52 still finished, ratings untouched. Timing should show roughly the holder's remaining sleep.
\set ON_ERROR_STOP off
\pset footer off
\timing on
SELECT id AS m52 FROM matches WHERE seed = 52 \gset
\echo 'prober: folding under the stale fence 10:00/2 (expect UPDATE 0 after a wait)'
EXECUTE c_fold ('2026-09-07 10:00:00+00', 2, :'m52',
  '[{"seat":0,"model_id":"20000000-0000-0000-0000-000000000002","ladder":"nano","mu":31,"sigma":6},{"seat":0,"model_id":"20000000-0000-0000-0000-000000000002","ladder":"open","mu":32,"sigma":5.5},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"nano","mu":26,"sigma":5.5},{"seat":1,"model_id":"10000000-0000-0000-0000-000000000001","ladder":"open","mu":25.5,"sigma":5.6}]');
\timing off
SELECT seed, status FROM matches WHERE seed = 52;
SELECT model_id, ladder, mu FROM ratings WHERE model_id = '20000000-0000-0000-0000-000000000002' ORDER BY ladder;
