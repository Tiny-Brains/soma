-- THE HOUR'S OPEN SNAPSHOT: the game's live season's Open field, as ladder_at() reads it at the top
-- of the hour. One rated ladder, so one row per season per hour; a class series filters this Open row
-- to same-size versions (rating_series). Idempotent -- a season that has this hour's row is skipped
-- before ladder_at() runs, so the other fifty-nine ticks of the hour cost one index probe. `$2` names
-- the hour, and the clock sends none: the current one.
INSERT INTO ladder_snapshots (season_id, ladder, at, version_ids, ratings)
SELECT s.id, 'open'::ladder, h.at, coalesce(f.version_ids, '{}'), coalesce(f.ratings, '{}')
  FROM seasons s
 CROSS JOIN (SELECT coalesce(($2)::timestamptz, date_trunc('hour', now())) AS at) h
 CROSS JOIN LATERAL (SELECT array_agg(a.version_id ORDER BY a.rank) AS version_ids,
                            array_agg(a.conservative::real ORDER BY a.rank) AS ratings
                       FROM ladder_at(s.id, 'open'::ladder, h.at) a) f
 WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL AND s.submissions_open_at <= h.at
   AND NOT EXISTS (SELECT 1 FROM ladder_snapshots x WHERE x.season_id = s.id AND x.at = h.at)
ON CONFLICT (season_id, ladder, at) DO NOTHING
