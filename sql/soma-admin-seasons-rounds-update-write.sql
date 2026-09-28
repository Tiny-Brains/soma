-- EDIT OR CANCEL ONE ROUND, a platform admin's. A WAITING round takes any of its numbers and a new
-- start (not in the past), or `cancel`: it then never starts, and the clock schedules the next one
-- on the grid. A STARTED round takes only `games`: the finals can be extended or cut short while
-- they run, and a weekly round's quota changed, both for every entry at once. A cancelled round
-- takes nothing. When a posted countdown's round moves or is cancelled, its line moves or ends in
-- the same statement. Writes nothing on anything else -- `why` says which. Audited.
WITH r AS (
    SELECT x.season_id, x.n, x.applied_at
      FROM season_rounds x
      JOIN seasons se ON se.id = x.season_id AND se.closed_at IS NULL
      JOIN games g    ON g.id = se.game_id
     WHERE g.slug = ($1)::text AND se.slug = ($2)::text AND x.n = ($3)::int
       AND x.cancelled_at IS NULL
       FOR UPDATE OF x
), edited AS (
    UPDATE season_rounds x
       SET starts_at    = coalesce(($4)::timestamptz, x.starts_at),
           games        = coalesce(($5)::float8::int, x.games),
           sigma_floor  = coalesce(($6)::float8, x.sigma_floor),
           mu_shrink    = coalesce(($7)::float8, x.mu_shrink),
           warn_minutes = coalesce(($8)::float8::int, x.warn_minutes),
           cancelled_at = CASE WHEN coalesce(($9)::boolean, false) THEN now() END
      FROM r
     WHERE x.season_id = r.season_id AND x.n = r.n
       AND season_round_numbers_ok(($5)::float8, ($6)::float8, ($7)::float8, ($8)::float8)
       AND (($4)::timestamptz IS NULL OR ($4)::timestamptz > now() - interval '1 minute')
       AND (r.applied_at IS NULL
         OR (($4)::timestamptz IS NULL AND ($6)::float8 IS NULL AND ($7)::float8 IS NULL
             AND ($8)::float8 IS NULL AND NOT coalesce(($9)::boolean, false)))
       AND (($4)::timestamptz IS NOT NULL OR ($5)::float8 IS NOT NULL OR ($6)::float8 IS NOT NULL
         OR ($7)::float8 IS NOT NULL OR ($8)::float8 IS NOT NULL OR coalesce(($9)::boolean, false))
 RETURNING x.season_id, x.n, x.kind, x.starts_at, x.games, x.cancelled_at
), moved AS (
    UPDATE announcements a
       SET at = e.starts_at,
           ends_at = CASE WHEN e.cancelled_at IS NOT NULL THEN now() ELSE e.starts_at END
      FROM edited e
     WHERE a.source = 'round:' || e.season_id || ':' || e.n
 RETURNING a.id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($10)::uuid, CASE WHEN e.cancelled_at IS NOT NULL THEN 'season.round_cancel'
                        ELSE 'season.round_edit' END,
       'season', ($2)::text,
       jsonb_strip_nulls(jsonb_build_object('game', ($1)::text, 'n', e.n, 'kind', e.kind,
                          'starts_at', ($4)::timestamptz, 'games', ($5)::float8,
                          'sigma_floor', ($6)::float8, 'mu_shrink', ($7)::float8,
                          'warn_minutes', ($8)::float8))
  FROM edited e
