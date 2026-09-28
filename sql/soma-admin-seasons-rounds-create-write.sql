-- SCHEDULE A ROUND OR THE FINALS, a platform admin's. The next number, the admin's numbers, and a
-- start that defaults to `warn_minutes` from now so the countdown runs its whole length (15 when
-- unsaid). Writes nothing -- and `why` says which -- for a closed season, a season with a round
-- already waiting (move or cancel that one instead), a start in the past, numbers
-- season_round_numbers_ok() refuses, a round after the finals, or finals that cannot start:
--   * only once the window has closed, so every entry's last submission is in;
--   * only with nothing still being admitted, so none of those is left out;
--   * and only once a season.
-- Audited in the same statement.
WITH s AS (
    SELECT se.id, se.submissions_close_at
      FROM seasons se JOIN games g ON g.id = se.game_id
     WHERE g.slug = ($1)::text AND se.slug = ($2)::text AND se.closed_at IS NULL
), made AS (
    INSERT INTO season_rounds (season_id, n, kind, starts_at, games, sigma_floor, mu_shrink,
                               warn_minutes, created_by)
    SELECT s.id,
           coalesce((SELECT max(r.n) FROM season_rounds r WHERE r.season_id = s.id), 0) + 1,
           ($3)::text,
           coalesce(($4)::timestamptz,
                    now() + make_interval(mins => coalesce(($8)::float8, 15)::int)),
           ($5)::float8::int, ($6)::float8, coalesce(($7)::float8, 0),
           coalesce(($8)::float8, 15)::int, ($9)::uuid
      FROM s
     WHERE ($3)::text IN ('round', 'finals')
       AND ($5)::float8 IS NOT NULL
       AND season_round_numbers_ok(($5)::float8, ($6)::float8, ($7)::float8, ($8)::float8)
       AND (($4)::timestamptz IS NULL OR ($4)::timestamptz > now() - interval '1 minute')
       AND NOT EXISTS (SELECT 1 FROM season_rounds w
                        WHERE w.season_id = s.id AND w.applied_at IS NULL AND w.cancelled_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM season_rounds f
                        WHERE f.season_id = s.id AND f.kind = 'finals' AND f.cancelled_at IS NULL)
       AND (($3)::text = 'round'
         OR (s.submissions_close_at <= now()
             AND NOT EXISTS (SELECT 1 FROM model_versions v
                              WHERE v.season_id = s.id AND v.status IN ('testing', 'verified'))))
    ON CONFLICT DO NOTHING
 RETURNING season_id, n, kind, starts_at, games, sigma_floor, mu_shrink, warn_minutes
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($9)::uuid, 'season.round', 'season', ($2)::text,
       jsonb_build_object('game', ($1)::text, 'n', made.n, 'kind', made.kind,
                          'starts_at', made.starts_at, 'games', made.games,
                          'sigma_floor', made.sigma_floor, 'mu_shrink', made.mu_shrink,
                          'warn_minutes', made.warn_minutes)
  FROM made
