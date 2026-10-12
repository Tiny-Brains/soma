-- THE CLOSED SEASONS' FINGERPRINT, read from schema :sch into the temp table :into -- one row per
-- closed season. \i'd by drop-legacy.sql, once for `public` and once for `legacy`, the copy the
-- cutover took: equal rows mean nothing the cutover kept of a closed season has moved since.
--
-- What a season's place in history is: every rating and rating event of its versions, its podium,
-- every seat of its matches, its versions and their status, how many matches it played, when it
-- closed and on which engine. Hashes only, so it prints nothing a competitor wrote.

CREATE TEMP TABLE :"into" AS
SELECT s.slug,
       (SELECT md5(string_agg(concat_ws('|', r.version_id, r.ladder, r.mu, r.sigma, r.conservative, r.matches_played), ','
                              ORDER BY r.version_id, r.ladder))
          FROM :"sch".ratings r JOIN :"sch".model_versions v ON v.id = r.version_id WHERE v.season_id = s.id) AS ratings_md5,
       (SELECT md5(string_agg(concat_ws('|', e.version_id, e.ladder, e.seq, e.match_id, e.mu_after, e.sigma_after), ','
                              ORDER BY e.version_id, e.ladder, e.seq))
          FROM :"sch".rating_events e JOIN :"sch".model_versions v ON v.id = e.version_id WHERE v.season_id = s.id) AS events_md5,
       (SELECT md5(string_agg(concat_ws('|', p.ladder, p.place, p.version_id, p.rating), ',' ORDER BY p.ladder, p.place))
          FROM :"sch".season_podium p WHERE p.season_id = s.id) AS podium_md5,
       (SELECT md5(string_agg(concat_ws('|', ms.match_id, ms.seat, ms.version_id, ms.rank, ms.score), ','
                              ORDER BY ms.match_id, ms.seat))
          FROM :"sch".match_seats ms JOIN :"sch".matches m ON m.id = ms.match_id WHERE m.season_id = s.id) AS seats_md5,
       (SELECT md5(string_agg(concat_ws('|', v.id, v.status), ',' ORDER BY v.id))
          FROM :"sch".model_versions v WHERE v.season_id = s.id) AS versions_md5,
       s.matches_played,
       extract(epoch FROM s.closed_at) AS closed_epoch,
       s.engine_digest
  FROM :"sch".seasons s
 WHERE s.closed_at IS NOT NULL;
