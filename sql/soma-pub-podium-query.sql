-- A season's frozen podium (season_podium, written by the close), by ladder, each place with its
-- owner's newest counted match of that season to watch, read backwards off each of the owner's
-- versions' rating_events rather than sorting every match they played. A live season has none yet.
WITH se AS (
    SELECT s.id, s.slug, s.name, s.closed_at
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = ($2)::text
)
SELECT json_build_object(
        'season', se.slug,
        'season_name', se.name,
        'closed', se.closed_at IS NOT NULL,
        'closed_at', se.closed_at,
        'ladders', coalesce((SELECT json_object_agg(l.ladder, l.places)
                               FROM (SELECT p.ladder, json_agg(json_build_object(
                                         'place', p.place, 'owner', u.handle,
                                         'model_id', e.id, 'model', e.name,
                                         'version_id', v.id, 'version', v.version,
                                         'rating', round(p.rating::numeric, 2),
                                         'latest_match', match_ref_json((
                                             SELECT m.id
                                               FROM models oe
                                               JOIN model_versions ov ON ov.model_id = oe.id AND ov.season_id = se.id
                                              CROSS JOIN LATERAL (SELECT ev.match_id FROM rating_events ev
                                                                   WHERE ev.version_id = ov.id AND ev.ladder = 'open' AND ev.seq > 0
                                                                   ORDER BY ev.seq DESC LIMIT 1) le
                                               JOIN matches m         ON m.id = le.match_id
                                              WHERE oe.owner_id = p.owner_id AND match_counted(m)
                                              ORDER BY m.played_at DESC, m.id DESC
                                              LIMIT 1)))
                                         ORDER BY p.place) AS places
                                       FROM season_podium p
                                       JOIN model_versions v ON v.id = p.version_id
                                       JOIN models e         ON e.id = v.model_id
                                       JOIN users u          ON u.id = p.owner_id
                                      WHERE p.season_id = se.id
                                      GROUP BY p.ladder) l), '{}'::json)) AS body
  FROM se
