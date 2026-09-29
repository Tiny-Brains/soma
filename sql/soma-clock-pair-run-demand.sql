WITH live AS (
    -- THE ONE SEASON THIS TICK IS PAIRING (N30). Seasons overlap, so "the live season" is no longer a
    -- single row; the pick statement chose one live season of the game (the emptiest queue) and passes
    -- its id here, and each season is paired round-robin over the ticks. Its rules come with it: every
    -- cap below is coalesce(rule, var), so a season that declares nothing paces exactly as the deploy.
    -- The roster epoch below is per game and is the fence the insert carries.
    SELECT id, rules, fill, fleet, engine_digest FROM seasons WHERE id = ($1)::uuid AND closed_at IS NULL
), rnd AS (
    -- THE SEASON'S CURRENT ROUND, when it is played in rounds or has started its finals: the newest
    -- season_rounds row count has applied. It turns the pacing from "until settled" into "until
    -- every version has the round's games", which is what stops a version's age being its score.
    SELECT r.n, r.kind, r.games
      FROM live CROSS JOIN LATERAL season_round(live.id) r
     WHERE r.n IS NOT NULL
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
           (live.rules -> 'pairing' ->> 'queue_share_max')::int                          AS queue_share_max,
           (SELECT n FROM rnd)                                                           AS round,
           (SELECT games FROM rnd)                                                       AS quota,
           coalesce((SELECT kind = 'finals' FROM rnd), false)                            AS finals,
           -- THE IDLE FILL's target, null while it is off. The finals ignore it: their number is a
           -- wall every entry stops at, and no idle lane may carry one past it.
           CASE WHEN (live.fill ->> 'enabled')::bool AND NOT coalesce((SELECT kind = 'finals' FROM rnd), false)
                THEN (live.fill ->> 'games')::int END                                    AS fill_games,
           coalesce((live.fill ->> 'headroom')::int, 0)                                  AS headroom
      FROM live
), maps AS (
    -- THE BOARDS IN PLAY, read on every run: the season's ENABLED maps, which an admin may
    -- change while the season is live. The season is the only source -- there is no deploy list to
    -- fall back to -- so a season with none enabled pairs nothing, the same paused state as no
    -- season at all. A match already queued keeps the board it was paired on.
    --
    -- AND ONLY THE BOARDS THE FLEET COULD FINISH. `seats_claimable` is the gate's own fit asked of
    -- the whole fleet instead of one runner, so pair never queues a row no runner can take: those
    -- sit `pending` for ever -- the reap touches only `claimed` and `running` -- and once
    -- `pair_depth_target` of them have piled up the season stops pairing ANYTHING, with the claim
    -- answering `{"idle": true}` and nothing naming the board. A default runner derives
    -- `seat_concurrency` from `cores / lanes`, so on a small node that is 1, and at ants' 1000 ms x
    -- 1000 turns every board above two seats fails the inequality -- and `ants/maps/` ships boards
    -- of 3, 4, 6 and 8. A board that no runner can hold is simply not paired on until one can; the
    -- admin's enabled list is untouched, and `soma-admin-shared-rounds` is where the fleet is read.
    SELECT sm.id, sm.players
      FROM season_maps sm JOIN live ON live.id = sm.season_id
     WHERE sm.enabled
       AND seats_claimable(live.id, sm.players, ($7)::int, ($8)::int)
     ORDER BY sm.added_at, sm.map_id
), rg AS (
    -- Each version's rated games in the current round (none without one).
    SELECT g.version_id, g.games
      FROM lim CROSS JOIN LATERAL round_games(($1)::uuid, lim.round) g
     WHERE lim.round IS NOT NULL
), v AS (
    -- ONE RATED LADDER: a version settles on Open. Its sigma and match count are the Open row's;
    -- there is no per-class rating to reconcile, so no reachability test and no aggregate. The weight
    -- class is still carried, for the pool below and for same-class-preferred matchmaking.
    --
    -- `window_played` is what the round's quota and the idle fill count: the round's games while
    -- the season has a round, otherwise every game the version has played this season.
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class, u.role = 'baseline' AS baseline,
           r.sigma, r.matches_played AS played,
           CASE WHEN lim.round IS NOT NULL THEN coalesce(rg.games, 0)
                ELSE coalesce(r.matches_played, 0) END AS window_played
      FROM model_versions vv
      JOIN models e  ON e.id = vv.model_id
      JOIN users u   ON u.id = e.owner_id
      JOIN live      ON live.id = vv.season_id
      CROSS JOIN lim
      LEFT JOIN ratings r ON r.version_id = vv.id AND r.ladder = 'open'
      LEFT JOIN rg        ON rg.version_id = vv.id
     -- A RETIRED ENTRY asks for nothing and is seated opposite nobody: its owner took it out, and
     -- its standing is kept as it was (the pool below leaves it out too).
     WHERE vv.status = 'active' AND e.retired_at IS NULL
), f AS (
    -- In flight INCLUDES a finished row count has not yet folded: its result is what the next
    -- pairing's prior will move, which is the whole reason the cap exists. Without it, in the ten
    -- seconds between Kalam finishing a burst and count folding it, played is still 0 and in_flight
    -- is 0, and pair would insert a second burst. `in_window` is the part of it that will count
    -- toward the window: the current round's rows (a row paired before a reset counts for the round
    -- it was paired in), or every rated row there is when the season has no round.
    SELECT s.version_id AS model_id, count(*) AS in_flight,
           count(*) FILTER (WHERE m.trial_version_id IS NULL
                              AND m.round IS NOT DISTINCT FROM (SELECT round FROM lim)) AS in_window
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.season_id = (SELECT id FROM live)
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.version_id
), w AS (
    -- No branch for a baseline in the pacing, and none may come back: it is paced like every
    -- version. The one thing a baseline does alone is sit opposite every trial (the trials
    -- statement's), and in the finals, where it is not an entry, it has no wall (`rooms` below).
    --
    -- TWO WANTS. `base` is what the season asks for: a round's quota, in bursts of at most `burst`
    -- in flight; or, with no round, the settling rule (placement, then steady_cap until sigma is at
    -- or below settled_sigma, then nothing of its own). `topup` is the idle fill's: toward
    -- `fill.games` in the window, in the same bursts. The larger is the version's want; `target` is
    -- the most games it may reach in the window, what its room below is measured from.
    SELECT v.model_id, v.owner_id, v.weight_class, v.baseline, v.sigma, v.played, v.window_played,
           coalesce(f.in_flight, 0) AS in_flight,
           coalesce(f.in_window, 0) AS in_window,
           CASE WHEN lim.finals                      THEN 'finals'
                WHEN lim.round IS NOT NULL           THEN CASE WHEN v.window_played < lim.quota
                                                               THEN 'quota' ELSE 'met' END
                WHEN v.played < lim.burst            THEN 'placement'
                WHEN v.sigma  > lim.settled_sigma    THEN 'unsettled'
                ELSE                                      'settled' END AS state,
           -- A baseline asks for nothing of its own in the finals: it is not an entry, only the seat
           -- opposite the last entry short of its games -- and one that asked would keep the queue
           -- full for ever, and the finals would never be done.
           CASE WHEN lim.finals AND v.baseline THEN 0
                WHEN lim.round IS NOT NULL
                THEN greatest(least(lim.burst - coalesce(f.in_flight, 0),
                                    lim.quota - v.window_played - coalesce(f.in_window, 0)), 0)
                ELSE greatest(CASE WHEN v.played < lim.burst         THEN lim.burst
                                   WHEN v.sigma  > lim.settled_sigma THEN lim.steady_cap
                                   ELSE                                   0 END
                              - coalesce(f.in_flight, 0), 0) END AS base,
           CASE WHEN lim.fill_games IS NOT NULL
                THEN greatest(least(lim.burst - coalesce(f.in_flight, 0),
                                    lim.fill_games - v.window_played - coalesce(f.in_window, 0)), 0)
                ELSE 0 END AS topup,
           CASE WHEN lim.round IS NOT NULL OR lim.fill_games IS NOT NULL
                THEN greatest(coalesce(lim.quota, 0), coalesce(lim.fill_games, 0)) END AS target
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
     WHERE m.season_id = (SELECT id FROM live) AND m.trial_version_id IS NULL
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY e.owner_id
), wants AS (
    -- pairing.queue_share_max caps ONE OWNER'S share of the queue across every entry they hold.
    -- Allocated with a running sum rather than per row: `least(want, share)` on each row would let
    -- each of a competitor's five models claim the whole budget, which is five times the cap.
    -- The order is deterministic (raw want DESC, fewest games in the window, model_id) because the
    -- plugin must be replayable from this document alone; the plugin orders its queue the same way.
    SELECT w.model_id, w.owner_id, w.weight_class, w.state, w.sigma, w.in_flight, w.base,
           -- `played` is the window's games: the plugin serves equal wants least-played first.
           w.window_played AS played,
           greatest(least(
               greatest(w.base, w.topup),
               coalesce(lim.queue_share_max, 2147483647)
                 - coalesce(ol.in_flight, 0)
                 - coalesce(sum(greatest(w.base, w.topup)) OVER (
                       PARTITION BY w.owner_id
                       ORDER BY greatest(w.base, w.topup) DESC, w.window_played, w.model_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
           ), 0) AS want
      FROM w CROSS JOIN lim LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id
), pool AS (
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class,
           -- Each version has one rated row, on Open. It is presented under BOTH the 'open' label and
           -- the version's own class label, carrying the same mu/sigma, so the pairing plugin -- which
           -- reads the affinity rating of the "shared ladder" (the class for a same-class pair, else
           -- Open) -- finds a number either way, with no per-class rating and no plugin change.
           (SELECT json_agg(json_build_object('ladder', l.ladder, 'mu', r.mu, 'sigma', r.sigma)
                            ORDER BY l.ladder)
              FROM ratings r
              CROSS JOIN LATERAL (VALUES ('open'::ladder), (vv.weight_class)) AS l (ladder)
             WHERE r.version_id = vv.id AND r.ladder = 'open' AND l.ladder IS NOT NULL) AS ratings
      FROM model_versions vv
      JOIN models e ON e.id = vv.model_id
      JOIN live     ON live.id = vv.season_id
     WHERE vv.status = 'active' AND e.retired_at IS NULL
), played AS (
    SELECT s.version_id AS model_id, m.season_map_id AS map, count(*) AS n
      FROM match_seats s JOIN matches m ON m.id = s.match_id
     WHERE m.season_id = (SELECT id FROM live) AND m.status IN ('finished', 'rated')
     GROUP BY s.version_id, m.season_map_id
), depth AS (
    SELECT count(*) AS pending FROM matches WHERE season_id = (SELECT id FROM live) AND status = 'pending'
), lanes AS (
    -- THE LANES THAT MAY PLAY THIS SEASON, read only while the idle fill is on: every live runner
    -- that plays matches, on the season's engine, heard from in the last ninety seconds (the roster
    -- tick is its heartbeat), and allowed by the season's fleet policy exactly as the claim reads it.
    -- Less what those runners already hold and what is already queued on the engine, in any season,
    -- and less the headroom an admin keeps free: what is left is the fill's room. It reads the
    -- fleet's capacity to size the demand, never the reverse -- nothing here sizes the fleet.
    SELECT greatest(
             coalesce((SELECT sum(lr.max_in_flight)
                         FROM live_runners lr JOIN runners r ON r.id = lr.id
                        WHERE r.plays_matches
                          AND r.engine_digest = live.engine_digest
                          AND r.last_seen_at > now() - runner_live_window()
                          AND CASE WHEN lr.season_id IS NOT NULL
                                   THEN lr.season_id = live.id AND (live.fleet ->> 'matches') IN ('own', 'both')
                                   ELSE (live.fleet ->> 'matches') IN ('platform', 'both') END), 0)
             - (SELECT count(*) FROM matches m
                 WHERE m.engine_digest = live.engine_digest
                   AND m.status IN ('pending', 'claimed', 'running'))
             - lim.headroom, 0) AS spare
      FROM live CROSS JOIN lim
     WHERE lim.fill_games IS NOT NULL
)
SELECT json_build_object(
         'demand', (SELECT coalesce(sum(want), 0) FROM wants),
         'depth',  (SELECT pending FROM depth),
         -- THE ROOM: what the season asks for, up to the depth target; or, when the idle fill has
         -- more to give, as much of it as there are free lanes -- whichever is larger, and never past
         -- the depth target, which stays a staleness cap on every queue.
         'room',   greatest(least(
                       greatest(least((SELECT coalesce(sum(least(base, want)), 0) FROM wants),
                                      ($5)::int - (SELECT pending FROM depth)),
                                least((SELECT coalesce(sum(want), 0) FROM wants),
                                      coalesce((SELECT spare FROM lanes), 0))),
                       ($5)::int - (SELECT pending FROM depth)), 0),
         'spare',  (SELECT spare FROM lanes),
         'round',  (SELECT json_build_object('n', lim.round, 'games', lim.quota, 'finals', lim.finals)
                      FROM lim WHERE lim.round IS NOT NULL),
         'wants',  (SELECT coalesce(json_agg(wants ORDER BY want DESC, played, model_id), '[]'::json)
                      FROM wants WHERE want > 0),
         'pool',   (SELECT coalesce(json_agg(pool), '[]'::json) FROM pool),
         'played', (SELECT coalesce(json_agg(played), '[]'::json) FROM played),
         -- The season's pairing policy, so the plugin reads it from the document it is already
         -- given rather than from a second input the caller has to keep in step. `strict_rooms` is
         -- the finals' wall: no entry is seated past its number of games.
         'limits', (SELECT json_build_object(
                        'self_pairing',         lim.self_pairing,
                        'cross_class_fraction', lim.cross_class_fraction,
                        'strict_rooms',         lim.finals,
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
                     WHERE lim.queue_share_max IS NOT NULL),
         -- How many more seats each VERSION may take in the window: its target less what it has
         -- played and holds there. Absent is uncapped: every version while the season has neither a
         -- round nor the fill, and a baseline in the finals, which is not an entry.
         --
         -- NEVER BELOW THE VERSION'S OWN `base`. `target` is `greatest(quota, fill_games)`, and the
         -- IDLE FILL IS NOT A QUOTA: with a fill and no round, `base` is the settling rule and is
         -- not bounded by the window at all, while this room would be. A version past `fill_games`
         -- then got `room = 0`, and `choose.rs` walls a drawn version on that regardless of
         -- `strict_rooms` -- so any entry still above `settled_sigma` stopped being paired, never
         -- settled, and a `closure.policy = settle` season never closed, while `demand` went on
         -- reporting work. The fill may only RAISE a version's room; what the season's own rule
         -- asks for is served either way.
         'rooms',  (SELECT coalesce(json_agg(json_build_object(
                        'model_id', w.model_id,
                        'room', greatest(w.target - w.window_played - w.in_window, w.base, 0))), '[]'::json)
                      FROM w CROSS JOIN lim
                     WHERE w.target IS NOT NULL AND NOT (lim.finals AND w.baseline))) AS body,
       (SELECT epoch FROM clocks WHERE key = 'roster') AS epoch
