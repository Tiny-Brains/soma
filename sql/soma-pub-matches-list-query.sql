WITH season AS (
    SELECT s.id, s.slug
    FROM games g, current_season(g.id, ($2)::text) s
    WHERE ($1)::text IS NOT NULL
    AND g.slug = ($1)::text ),
lim AS (
    SELECT least(greatest(coalesce(($8)::int, 25), 1), 60) AS n ),
cur AS (
    SELECT CASE
        WHEN coalesce(($14)::text, 'newest') = 'newest' THEN split_part(($7)::text, '|', 1)::timestamptz
        END AS at, CASE
        WHEN ($14)::text IN ('closest', 'longest') THEN split_part(($7)::text, '|', 1)::int
        END AS ki, CASE
        WHEN ($14)::text = 'upset' THEN split_part(($7)::text, '|', 1)::float8
        END AS kf, CASE
        WHEN ($14)::text IS DISTINCT FROM 'discussed' THEN split_part(($7)::text, '|', 2)::uuid
        END AS id, CASE
        WHEN ($14)::text = 'discussed' THEN coalesce(($7)::text::int, 0)
        ELSE 0
        END AS off ),
top10 AS (
    SELECT f.version_id
    FROM season, ladder_field(season.id, 'open') f
    WHERE ($16)::text IN ('true', '1')
    ORDER BY f.conservative DESC, f.version_id
    LIMIT 10 ),
top_matches AS (
    -- Driven from the top ten's own seats, so `top` costs their matches, not a count per match.
    SELECT ms.match_id
    FROM match_seats ms
    WHERE ms.version_id IN (SELECT version_id
        FROM top10)
    GROUP BY ms.match_id
    HAVING count(*) >= 2 ),
matched AS NOT MATERIALIZED (
    -- Each seat filter is an IN over match_seats rather than an EXISTS per row, so the planner may
    -- drive a model's, a version's or an owner's listing (and its total) from their seats.
    SELECT mt AS m, mt.id, mt.played_at, mt.margin, mt.upset, mt.turns
    FROM matches mt
    WHERE match_public(mt)
    AND (($15)::timestamptz IS NULL
        OR ($14)::text = 'discussed'
        OR mt.played_at >= ($15)::timestamptz)
    AND (($16)::text IS NULL
        OR ($16)::text NOT IN ('true', '1')
        OR mt.id IN (SELECT match_id
            FROM top_matches))
    AND (($1)::text IS NULL
        OR mt.season_id = (SELECT id
            FROM season))
    AND (mt.trial_version_id IS NULL
        OR ($9)::uuid IS NOT NULL
        OR ($11)::uuid IS NOT NULL)
    AND (($9)::uuid IS NULL
        OR mt.id IN (SELECT ms.match_id
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            WHERE mv.model_id = ($9)::uuid))
    AND (($17)::uuid IS NULL
        OR mt.id IN (SELECT ms.match_id
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            WHERE mv.model_id = ($17)::uuid))
    AND (($11)::uuid IS NULL
        OR mt.id IN (SELECT ms.match_id
            FROM match_seats ms
            WHERE ms.version_id = ($11)::uuid))
    AND (($10)::text IS NULL
        OR mt.id IN (SELECT ms.match_id
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            JOIN models me ON me.id = mv.model_id
            JOIN users ou ON ou.id = me.owner_id
            WHERE lower(ou.handle) = lower(($10)::text)))
    AND (($3)::text IS NULL
        OR ($3)::ladder = ANY (mt.ladders))
    AND (($4)::text IS NULL
        OR EXISTS (SELECT 1
            FROM match_seats ms
            JOIN model_versions mv ON mv.id = ms.version_id
            WHERE ms.match_id = mt.id
            AND mv.weight_class = ($4)::ladder))
    AND (($5)::text IS NULL
        OR EXISTS (SELECT 1
            FROM season_maps sm
            WHERE sm.id = mt.season_map_id
            AND sm.map_id = ($5)::text))
    AND (($12)::int IS NULL
        OR mt.seat_count >= ($12)::int)
    AND (($13)::int IS NULL
        OR mt.seat_count <= ($13)::int)
    -- A shared first place is the one rated match with no margin, so drawn and decided read the
    -- stored key; a disqualification is a seat at its strike ceiling.
    AND (($6)::text IS NULL
        OR CASE ($6)::text
        WHEN 'dq' THEN EXISTS (SELECT 1
            FROM match_seats ms
            WHERE ms.match_id = mt.id
            AND ms.strikes >= mt.strike_ceiling)
        WHEN 'drawn' THEN mt.status = 'rated'
        AND mt.margin IS NULL
        WHEN 'decided' THEN mt.margin IS NOT NULL
        ELSE true
        END) ),
discussed AS (
    -- Live comments in the window (seven days unless `since` says), per match thread.
    SELECT t.match_id, count(*) AS n
    FROM comments c
    JOIN threads t ON t.id = c.thread_id
    WHERE ($14)::text = 'discussed'
    AND c.state = 'live'
    AND c.created_at >= coalesce(($15)::timestamptz, now() - interval '7 days')
    AND t.match_id IS NOT NULL
    GROUP BY t.match_id ),
ranked AS NOT MATERIALIZED (
    -- The discussed matches that pass the filters, as (n, id) pairs only: the whole rows are read
    -- for the page, not for the sort.
    SELECT d.match_id AS id, d.n
    FROM discussed d
    JOIN matched x ON x.id = d.match_id ),
page AS (
    (SELECT x.m, x.id, x.played_at, row_number() OVER (ORDER BY x.played_at DESC, x.id DESC) AS ord,
            (to_json(x.played_at) #>> '{}') || '|' || x.id::text AS cur
        FROM matched x
        WHERE coalesce(($14)::text, 'newest') = 'newest'
        AND (($7)::text IS NULL
            OR (x.played_at, x.id) < ((SELECT at
                    FROM cur), (SELECT id
                    FROM cur)))
        ORDER BY x.played_at DESC, x.id DESC
        LIMIT (SELECT n
            FROM lim))
    UNION ALL
    (SELECT x.m, x.id, x.played_at, row_number() OVER (ORDER BY x.margin, x.id) AS ord, x.margin::text || '|'
            || x.id::text AS cur
        FROM matched x
        WHERE ($14)::text = 'closest'
        AND x.margin IS NOT NULL
        AND (($7)::text IS NULL
            OR (x.margin, x.id) > ((SELECT ki
                    FROM cur), (SELECT id
                    FROM cur)))
        ORDER BY x.margin, x.id
        LIMIT (SELECT n
            FROM lim))
    UNION ALL
    (SELECT x.m, x.id, x.played_at, row_number() OVER (ORDER BY x.upset DESC, x.id DESC) AS ord,
            x.upset::text || '|' || x.id::text AS cur
        FROM matched x
        WHERE ($14)::text = 'upset'
        AND x.upset IS NOT NULL
        AND (($7)::text IS NULL
            OR (x.upset, x.id) < ((SELECT kf
                    FROM cur), (SELECT id
                    FROM cur)))
        ORDER BY x.upset DESC, x.id DESC
        LIMIT (SELECT n
            FROM lim))
    UNION ALL
    (SELECT x.m, x.id, x.played_at, row_number() OVER (ORDER BY x.turns DESC, x.id DESC) AS ord,
            x.turns::text || '|' || x.id::text AS cur
        FROM matched x
        WHERE ($14)::text = 'longest'
        AND x.turns IS NOT NULL
        AND (($7)::text IS NULL
            OR (x.turns, x.id) < ((SELECT ki
                    FROM cur), (SELECT id
                    FROM cur)))
        ORDER BY x.turns DESC, x.id DESC
        LIMIT (SELECT n
            FROM lim))
    UNION ALL
    (SELECT mt AS m, mt.id, mt.played_at, p.ord, ((SELECT off
                    FROM cur) + (SELECT n
                    FROM lim))::text AS cur
        FROM (SELECT r.id, row_number() OVER (ORDER BY r.n DESC, r.id) AS ord
            FROM (SELECT r.id, r.n
                FROM ranked r
                ORDER BY r.n DESC, r.id
                OFFSET (SELECT off
                    FROM cur)
                LIMIT (SELECT n
                    FROM lim)) r) p
        JOIN matches mt ON mt.id = p.id) ),
counted AS (
    SELECT count(*) AS n
    FROM (SELECT 1
        FROM matched
        WHERE ($14)::text IS DISTINCT FROM 'discussed'
        LIMIT 10001) x ),
counted_discussed AS (
    SELECT count(*) AS n
    FROM (SELECT 1
        FROM ranked
        LIMIT 10001) x )
SELECT json_build_object( 'season', (SELECT slug
        FROM season), 'total', CASE
    WHEN ($7)::text IS NULL THEN least(CASE
        WHEN ($14)::text = 'discussed' THEN (SELECT n
            FROM counted_discussed)
        ELSE (SELECT n
            FROM counted)
        END, 10000)
    END, 'total_capped', CASE
    WHEN ($7)::text IS NULL THEN CASE
        WHEN ($14)::text = 'discussed' THEN (SELECT n
            FROM counted_discussed)
        ELSE (SELECT n
            FROM counted)
        END > 10000
    END, 'matches', coalesce((SELECT json_agg(match_summary_json(p.m)
                ORDER BY p.ord)
            FROM page p), '[]'::json), 'sort', coalesce(($14)::text, 'newest'), 'next_cursor', CASE
    WHEN (SELECT count(*)
        FROM page) = (SELECT n
        FROM lim) THEN (SELECT x.cur
        FROM page x
        ORDER BY x.ord DESC
        LIMIT 1)
    END) AS body
