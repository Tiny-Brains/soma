WITH season AS (
    -- The live season supplies the digest and is what every seat must belong to. No live
    -- season, or a seat from another season, and nothing is inserted -- pair halts and re-reads.
    SELECT s.id, s.game_id, s.engine_digest, s.rules
      FROM seasons s
      JOIN games g ON g.id = s.game_id AND g.slug = ($2)::text
     WHERE s.closed_at IS NULL
), board AS (
    -- THE BOARD DECIDES THE SEAT COUNT, and the statement reads it rather than trusting the plan:
    -- an enabled map of THIS season, or nothing is inserted. A board disabled between pair's
    -- read and this insert is how a stale plan would otherwise queue a match on it.
    SELECT sm.id, sm.players
      FROM season_maps sm JOIN season ON season.id = sm.season_id
     WHERE sm.id = ($4)::uuid AND sm.enabled
), seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, v.id AS version_id, e.owner_id,
           v.weights_hash, v.manifest_hash, v.weight_class
      FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (version_id, ord)
      JOIN model_versions v ON v.id = seat.version_id
      JOIN models e         ON e.id = v.model_id
      JOIN season           ON season.id = v.season_id
     WHERE v.status = 'active'
        OR (v.status = 'verified' AND v.id = ($6)::uuid)
), m AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders,
                         trial_version_id, pairing_id, strike_ceiling)
    SELECT season.game_id, season.id, season.engine_digest, ($3)::bigint, board.id, board.players,
           CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[]
                WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1
                     THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[]
                ELSE ARRAY['open']::ladder[]
           END,
           ($6)::uuid, ($7)::uuid,
           -- THE RULE THE WAVE WILL PLAY BY, pinned onto the row here and read from it by Kalam
           -- and by count. NOT NULL on the column is deliberate: if both the season and the deploy
           -- were silent this insert fails, loudly, here -- where a halt is correct -- instead of
           -- Kalam comparing a strike count against null, which is TRUE, and forfeiting every seat
           -- on turn 0.
           coalesce((season.rules -> 'pairing' ->> 'forfeit_strikes')::smallint, ($8)::smallint)
      FROM season
      JOIN board ON true
      JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence
        ON true
     WHERE (SELECT count(*) FROM seated) = cardinality(($5)::uuid[])
       AND cardinality(($5)::uuid[]) = board.players
       -- SELF-PAIRING IS REFUSED HERE AND NOT ONLY IN THE PLUGIN. Two versions of one owner in one
       -- match is a free rating transfer between a competitor's own entries: the ladder is wrong,
       -- not merely worse, so it is correctness and belongs in the statement. The plugin's job is
       -- never to propose what this would refuse; this statement's job is to refuse it anyway.
       -- Trials are exempt: a trial is the candidate plus baselines, and the candidate's own owner
       -- is never among them.
       AND (($6)::uuid IS NOT NULL
         OR coalesce((season.rules -> 'pairing' ->> 'self_pairing')::bool, false)
         OR (SELECT count(DISTINCT owner_id) FROM seated) = cardinality(($5)::uuid[]))
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, paired_ratings)
SELECT m.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash,
       (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                         ORDER BY r.ladder)
          FROM ratings r WHERE r.version_id = s.version_id)
  FROM m, seated s
