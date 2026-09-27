-- ONE MODEL'S SEASON, the live one of its game (else the latest closed): its record, the last five
-- as cards, the win that gained most and the loss that cost most on Open, and its Open rank now
-- (ladder_field) and a week ago (the snapshot at or before then). The record is the fold's own
-- counters on its versions' Open ratings; everything else reads its versions' Open rating_events,
-- so it costs the model's matches, never the season's. A win is first alone (a stored margin), a
-- loss any place below first, a disqualification included.
WITH e AS (
    SELECT e.id, e.name, e.game_id FROM models e WHERE e.id = ($1)::uuid
), se AS (
    SELECT s.id, s.slug FROM e, public_season(e.game_id) s
), vs AS (
    SELECT v.id FROM e, se, model_versions v WHERE v.model_id = e.id AND v.season_id = se.id
), moved AS (
    SELECT m AS mt, m.id, m.played_at,
           (ev.mu_after - 3 * ev.sigma_after) - (ev.mu_before - 3 * ev.sigma_before) AS delta,
           ms.rank = 1 AND m.margin IS NOT NULL AS won,
           ms.rank > 1 AS lost
      FROM vs
      JOIN rating_events ev ON ev.version_id = vs.id AND ev.ladder = 'open' AND ev.seq > 0
      JOIN match_seats ms   ON ms.match_id = ev.match_id AND ms.seat = ev.seat
      JOIN matches m        ON m.id = ev.match_id
), last AS (
    SELECT x.mt, x.played_at, x.id
      FROM vs
     CROSS JOIN LATERAL (SELECT m AS mt, m.played_at, m.id
                           FROM rating_events ev JOIN matches m ON m.id = ev.match_id
                          WHERE ev.version_id = vs.id AND ev.ladder = 'open' AND ev.seq > 0
                          ORDER BY ev.seq DESC LIMIT 5) x
     ORDER BY x.played_at DESC, x.id DESC
     LIMIT 5
), field AS (
    SELECT f.version_id, row_number() OVER (ORDER BY f.conservative DESC, f.version_id) AS rank
      FROM se, ladder_field(se.id, 'open') f
), ago AS (
    SELECT sn.version_ids
      FROM se, ladder_snapshots sn
     WHERE sn.season_id = se.id AND sn.ladder = 'open' AND sn.at <= now() - interval '7 days'
     ORDER BY sn.at DESC
     LIMIT 1
)
SELECT json_build_object(
        'model_id', e.id,
        'model', e.name,
        'season', (SELECT se.slug FROM se),
        'record', (SELECT json_build_object(
                       'played', coalesce(sum(r.wins + r.draws + r.losses), 0),
                       'won',    coalesce(sum(r.wins), 0),
                       'drawn',  coalesce(sum(r.draws), 0),
                       'lost',   coalesce(sum(r.losses), 0))
                     FROM vs JOIN ratings r ON r.version_id = vs.id AND r.ladder = 'open'),
        'last_five', coalesce((SELECT json_agg(match_summary_json(l.mt) ORDER BY l.played_at DESC, l.id DESC)
                                 FROM last l), '[]'::json),
        'best_win', (SELECT json_build_object('delta', round(mv.delta::numeric, 2),
                                              'match', match_summary_json(mv.mt))
                       FROM moved mv
                      WHERE mv.won
                      ORDER BY mv.delta DESC, mv.id LIMIT 1),
        'worst_loss', (SELECT json_build_object('delta', round(mv.delta::numeric, 2),
                                                'match', match_summary_json(mv.mt))
                         FROM moved mv
                        WHERE mv.lost
                        ORDER BY mv.delta ASC, mv.id LIMIT 1),
        'rank', json_build_object(
            'now',            (SELECT min(f.rank) FROM field f JOIN vs ON vs.id = f.version_id),
            'field',          (SELECT count(*) FROM field),
            'week_ago',       (SELECT min(array_position(ago.version_ids, vs.id)) FROM ago, vs),
            'week_ago_field', (SELECT cardinality(ago.version_ids) FROM ago))) AS body
  FROM e
