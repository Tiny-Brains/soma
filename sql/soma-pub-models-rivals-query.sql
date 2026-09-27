-- WHO THIS MODEL MEETS, this season: per opposing model, the counted matches both sat in and how
-- many each won, where a win is the better rank. Ties count as played and neither. Starts from the
-- model's own Open rating_events -- which exist for rated matches that are not trials, and nothing
-- else -- so it costs the model's matches. Most losses first: home's "the neighbour you lose to
-- most" is the first row.
WITH e AS (
    SELECT e.id, e.game_id FROM models e WHERE e.id = ($1)::uuid
), se AS (
    SELECT s.id, s.slug FROM e, public_season(e.game_id) s
), lim AS (
    SELECT least(greatest(coalesce(($2)::int, 20), 1), 100) AS n
), mine AS (
    SELECT ms.match_id, ms.rank
      FROM e, se, model_versions v
      JOIN rating_events ev ON ev.version_id = v.id AND ev.ladder = 'open' AND ev.seq > 0
      JOIN match_seats ms   ON ms.match_id = ev.match_id AND ms.seat = ev.seat
     WHERE v.model_id = e.id AND v.season_id = se.id
), met AS (
    SELECT ov.model_id,
           count(*) AS played,
           count(*) FILTER (WHERE mine.rank < os.rank) AS won,
           count(*) FILTER (WHERE mine.rank > os.rank) AS lost
      FROM mine
      JOIN match_seats os    ON os.match_id = mine.match_id
      JOIN model_versions ov ON ov.id = os.version_id
     WHERE ov.model_id <> ($1)::uuid
     GROUP BY ov.model_id
)
SELECT json_build_object(
        'model_id', e.id,
        'season', (SELECT se.slug FROM se),
        'rivals', coalesce((SELECT json_agg(json_build_object(
                                'model_id', r.model_id, 'model', oe.name, 'owner', u.handle,
                                'baseline', u.role = 'baseline',
                                'played', r.played, 'won', r.won, 'lost', r.lost)
                                ORDER BY r.lost DESC, r.played DESC, r.model_id)
                              FROM (SELECT * FROM met ORDER BY lost DESC, played DESC, model_id
                                     LIMIT (SELECT n FROM lim)) r
                              JOIN models oe ON oe.id = r.model_id
                              JOIN users u   ON u.id = oe.owner_id), '[]'::json)) AS body
  FROM e
