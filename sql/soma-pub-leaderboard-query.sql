WITH season AS (
    SELECT s.id, s.slug, s.name, (s.closed_at IS NOT NULL) AS closed
    FROM games g, current_season(g.id, ($6)::text) s
    WHERE g.slug = ($1)::text ),
field AS (
    SELECT f.version_id
    FROM season, ladder_field(season.id, ($2)::ladder) f ),
page AS (
    SELECT row_number() OVER (ORDER BY r.conservative DESC, v.id) AS rank, v.id::text AS version_id,
        e.id::text AS model_id, e.name AS model, u.handle AS owner, v.version, v.weight_class::text
        AS class, v.size_bytes, r.conservative AS rating, (r.sigma > ($5)::float8) AS provisional,
        r.matches_played AS matches, (u.role = 'baseline') AS baseline, (SELECT (ev.mu_after - 3 *
                ev.sigma_after) - (ev.mu_before - 3 * ev.sigma_before)
        FROM rating_events ev
        WHERE ev.version_id = v.id
        AND ev.ladder = r.ladder
        AND ev.seq > 0
        ORDER BY ev.seq DESC
        LIMIT 1) AS trend, (SELECT coalesce(json_agg(round(h.c::numeric, 2)
                ORDER BY h.seq), '[]'::json)
        FROM (SELECT ev.seq, (ev.mu_after - 3 * ev.sigma_after) AS c
            FROM rating_events ev
            WHERE ev.version_id = v.id
            AND ev.ladder = r.ladder
            ORDER BY ev.seq DESC
            LIMIT 12) h) AS history
    FROM field
    JOIN model_versions v ON v.id = field.version_id
    JOIN models e ON e.id = v.model_id
    JOIN ratings r ON r.version_id = v.id
    AND r.ladder = ($2)::ladder
    JOIN users u ON u.id = e.owner_id
    ORDER BY r.conservative DESC, v.id
    OFFSET ($4)::int
    LIMIT ($3)::int)
SELECT json_build_object( 'season', (SELECT slug
        FROM season), 'season_name', (SELECT name
        FROM season), 'closed', (SELECT closed
        FROM season), 'total', (SELECT count(*)
        FROM field), 'entries', coalesce(json_agg(page
            ORDER BY page.rank), '[]'::json), 'next_cursor', CASE
    WHEN count(*) = ($3)::int THEN (($4)::int + ($3)::int)::text
    ELSE NULL
    END) AS body
FROM page
