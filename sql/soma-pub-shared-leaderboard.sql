-- SHARED by the public route (no session: $7 and $8 are null, the anonymous public) and the
-- member's /v1/private route (the session's claims): session_viewer() is the viewer, and a
-- private season is visible to whoever season_visible() lets see it.
WITH season AS (
    SELECT s.id, s.slug, s.name, (s.closed_at IS NOT NULL) AS closed,
           -- `provisional` is the season's own rule where it declares one, the deploy's otherwise.
           coalesce((s.rules -> 'rating' ->> 'settled_sigma')::float8, ($5)::float8) AS settled_sigma
    FROM games g, viewable_season(g.id, ($6)::text, session_viewer(($7)::uuid, ($8)::uuid)) s
    WHERE g.slug = ($1)::text ),
lim AS (
    SELECT least(greatest(($3)::int, 1), 200) AS n ),
-- THE SEASON'S CURRENT ROUND, if it is played in rounds or in its finals: each row then carries its
-- games in the round beside its games in the season, since the round's are the ones every version
-- has the same number of to play.
rnd AS (
    SELECT r.n, r.kind, r.games FROM season CROSS JOIN LATERAL season_round(season.id) r
     WHERE r.n IS NOT NULL ),
rg AS (
    SELECT g.version_id, g.games FROM season, rnd, round_games(season.id, rnd.n) g ),
field AS (
    SELECT f.version_id
    FROM season, ladder_field(season.id, ($2)::ladder) f ),
page AS (
    SELECT row_number() OVER (ORDER BY r.conservative DESC, v.id) AS rank, v.id::text AS version_id,
        e.id::text AS model_id, e.name AS model, u.handle AS owner, v.version, v.weight_class::text
        AS class, v.size_bytes, r.conservative AS rating, (r.sigma > (SELECT settled_sigma FROM season)) AS provisional,
        r.matches_played AS matches,
        CASE WHEN (SELECT n FROM rnd) IS NOT NULL THEN coalesce(rg.games, 0) END AS round_matches,
        (u.role = 'baseline') AS baseline, (SELECT (ev.mu_after - 3 *
                ev.sigma_after) - (ev.mu_before - 3 * ev.sigma_before)
        FROM rating_events ev
        WHERE ev.version_id = v.id
        AND ev.ladder = 'open'
        AND ev.seq > 0
        ORDER BY ev.seq DESC
        LIMIT 1) AS trend, (SELECT coalesce(json_agg(round(h.c::numeric, 2)
                ORDER BY h.seq), '[]'::json)
        FROM (SELECT ev.seq, (ev.mu_after - 3 * ev.sigma_after) AS c
            FROM rating_events ev
            WHERE ev.version_id = v.id
            AND ev.ladder = 'open'
            ORDER BY ev.seq DESC
            LIMIT 12) h) AS history
    FROM field
    JOIN model_versions v ON v.id = field.version_id
    JOIN models e ON e.id = v.model_id
    -- One rated ladder: the rating, trend and history are the Open row whatever field ($2) names.
    -- `field` (ladder_field) already restricted membership to the class, so row_number() over
    -- Open's conservative is the class rank -- consistent with the Open board by construction.
    JOIN ratings r ON r.version_id = v.id
    AND r.ladder = 'open'
    JOIN users u ON u.id = e.owner_id
    LEFT JOIN rg ON rg.version_id = v.id
    ORDER BY r.conservative DESC, v.id
    OFFSET ($4)::int
    LIMIT (SELECT n
        FROM lim))
SELECT json_build_object( 'season', (SELECT slug
        FROM season), 'season_name', (SELECT name
        FROM season), 'closed', (SELECT closed
        FROM season), 'round', (SELECT json_build_object('n', n, 'kind', kind, 'games', games)
        FROM rnd), 'total', (SELECT count(*)
        FROM field), 'entries', coalesce(json_agg(page
            ORDER BY page.rank), '[]'::json), 'next_cursor', CASE
    WHEN count(*) = (SELECT n
        FROM lim) THEN (($4)::int + (SELECT n
            FROM lim))::text
    ELSE NULL
    END) AS body,
       EXISTS (SELECT 1 FROM games WHERE slug = ($1)::text) AS found
FROM page
