WITH live AS (
    -- Only the live season's versions want anything or may be seated. No live season,
    -- no demand, nothing paired -- the paused state. The season's rules come with it: every cap
    -- below is coalesce(rule, var), so a season that declares nothing paces exactly as the deploy.
    SELECT id, rules FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), lim AS (
    SELECT coalesce((live.rules -> 'pairing' ->> 'burst')::int,             ($2)::int)    AS burst,
           coalesce((live.rules -> 'pairing' ->> 'steady_cap')::int,        ($3)::int)    AS steady_cap,
           coalesce((live.rules -> 'rating'  ->> 'settled_sigma')::float8,  ($4)::float8) AS settled_sigma,
           coalesce((live.rules -> 'pairing' ->> 'cross_class_fraction')::float8, ($6)::float8)
                                                                                         AS cross_class_fraction,
           coalesce((live.rules -> 'pairing' ->> 'self_pairing')::bool,     false)        AS self_pairing,
           -- NULL means uncapped, and it must stay NULL rather than become a sentinel here:
           -- Postgres least() SKIPS nulls, so `least(want, NULL)` is `want` and an absent cap
           -- would silently disable itself. Every use below coalesces explicitly.
           (live.rules -> 'pairing' ->> 'queue_share_max')::int                          AS queue_share_max
      FROM live
), maps AS (
    -- THE BOARDS IN PLAY, read on every run: the season's ENABLED maps, which an admin may
    -- change while the season is live. The season is the only source -- there is no deploy list to
    -- fall back to -- so a season with none enabled pairs nothing, the same paused state as no
    -- season at all. A match already queued keeps the board it was paired on.
    SELECT sm.id, sm.players
      FROM season_maps sm JOIN live ON live.id = sm.season_id
     WHERE sm.enabled
     ORDER BY sm.added_at, sm.map_id
), v AS (
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM model_versions vv
      JOIN models e ON e.id = vv.model_id
      JOIN live     ON live.id = vv.season_id
      LEFT JOIN ratings r ON r.version_id = vv.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM model_versions o
           WHERE o.season_id = vv.season_id AND o.status = 'active'
             AND o.weight_class = vv.weight_class AND o.id <> vv.id
      ) reach ON true
     WHERE vv.status = 'active'
     GROUP BY vv.id, e.owner_id, vv.weight_class
), f AS (
    -- In flight INCLUDES a finished row count has not yet folded: its result is what the next
    -- pairing's prior will move, which is the whole reason the cap exists. Without it, in the ten
    -- seconds between Kalam finishing a burst and count folding it, played is still 0 and in_flight
    -- is 0, and pair would insert a second burst.
    SELECT s.version_id AS model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.version_id
), w AS (
    -- No branch for a baseline, and none may come back: it is paced like every version.
    -- The one thing a baseline does alone is sit opposite every trial, which is P_TRIALS'.
    SELECT v.model_id, v.owner_id, v.weight_class, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.played < lim.burst         THEN 'placement'
                WHEN v.sigma  > lim.settled_sigma THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.played < lim.burst         THEN lim.burst
                WHEN v.sigma  > lim.settled_sigma THEN lim.steady_cap
                ELSE                                   0 END AS cap
      FROM v CROSS JOIN lim LEFT JOIN f ON f.model_id = v.model_id
), owner_load AS (
    -- What each owner already holds across ALL of their entries. Trials are EXCLUDED: a candidate
    -- whose owner is at their share would otherwise never get its trial and would eventually be
    -- rejected UNPLAYABLE for a queueing rule.
    SELECT e.owner_id, count(*) AS in_flight
      FROM match_seats st
      JOIN matches m       ON m.id = st.match_id
      JOIN model_versions o ON o.id = st.version_id
      JOIN models e         ON e.id = o.model_id
     WHERE m.game_id = ($1)::uuid AND m.trial_version_id IS NULL
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY e.owner_id
), wants AS (
    -- pairing.queue_share_max caps ONE OWNER'S share of the queue across every entry they hold.
    -- Allocated with a running sum rather than per row: `least(want, share)` on each row would let
    -- each of a competitor's five models claim the whole budget, which is five times the cap.
    -- The order is deterministic (want DESC, model_id) because the plugin must be replayable from
    -- this document alone.
    SELECT w.model_id, w.owner_id, w.weight_class, w.state, w.sigma, w.played, w.in_flight,
           greatest(least(
               greatest(w.cap - w.in_flight, 0),
               coalesce(lim.queue_share_max, 2147483647)
                 - coalesce(ol.in_flight, 0)
                 - coalesce(sum(greatest(w.cap - w.in_flight, 0)) OVER (
                       PARTITION BY w.owner_id
                       ORDER BY greatest(w.cap - w.in_flight, 0) DESC, w.model_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
           ), 0) AS want
      FROM w CROSS JOIN lim LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id
), pool AS (
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class,
           (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                            ORDER BY r.ladder) FROM ratings r WHERE r.version_id = vv.id) AS ratings
      FROM model_versions vv
      JOIN models e ON e.id = vv.model_id
      JOIN live     ON live.id = vv.season_id
     WHERE vv.status = 'active'
), played AS (
    SELECT s.version_id AS model_id, m.season_map_id AS map, count(*) AS n
      FROM match_seats s JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated')
     GROUP BY s.version_id, m.season_map_id
), depth AS (
    SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending'
)
SELECT json_build_object(
         'demand', (SELECT coalesce(sum(want), 0) FROM wants),
         'depth',  (SELECT pending FROM depth),
         'room',   greatest(least((SELECT coalesce(sum(want), 0) FROM wants),
                                  ($5)::int - (SELECT pending FROM depth)), 0),
         'wants',  (SELECT coalesce(json_agg(wants ORDER BY want DESC, sigma DESC), '[]'::json)
                      FROM wants WHERE want > 0),
         'pool',   (SELECT coalesce(json_agg(pool), '[]'::json) FROM pool),
         'played', (SELECT coalesce(json_agg(played), '[]'::json) FROM played),
         -- The season's pairing policy, so the plugin reads it from the document it is already
         -- given rather than from a second input the caller has to keep in step.
         'limits', (SELECT json_build_object(
                        'self_pairing',         lim.self_pairing,
                        'cross_class_fraction', lim.cross_class_fraction,
                        'maps',                 (SELECT coalesce(json_agg(json_build_object(
                                                     'id', mp.id, 'players', mp.players)), '[]'::json)
                                                   FROM maps mp)) FROM lim),
         -- How many more seats each owner may hold. ABSENT MEANS UNCAPPED -- the same convention
         -- `want` uses -- and a season that sets a share names every owner, baselines included.
         'owners', (SELECT coalesce(json_agg(json_build_object(
                        'owner_id', o.owner_id,
                        'in_flight', o.in_flight,
                        'room', greatest(lim.queue_share_max - o.in_flight, 0))), '[]'::json)
                      FROM (SELECT DISTINCT w.owner_id,
                                   coalesce(max(ol.in_flight), 0) AS in_flight
                              FROM w LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id
                             GROUP BY w.owner_id) o, lim
                     WHERE lim.queue_share_max IS NOT NULL)) AS body
