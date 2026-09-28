-- IMPORT BOARDS FROM ANOTHER SEASON (Q7): every board of the season `from` ($3) -- or those `maps`
-- (map ids) names -- copied into this live season as uploaded boards are: the same file, header
-- and digest, SWITCHED OFF, added by the caller. Switching one on re-runs the engine's check under
-- this season's engine, as for any upload, so a board the new engine refuses never plays. A board
-- this season already holds (by id or by digest) is left as it is. The source must be a season the
-- caller may see. One audit line a board. $4 is the whole request, an object: a list bound on its
-- own would reach the cast as raw text when it is a string, and fail the bind before `why` could
-- name it; read out of the object, a `maps` that is not an array imports nothing.
WITH tgt AS (
    SELECT s.id FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = ($2)::text AND s.closed_at IS NULL
), src AS (
    SELECT s.id FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text AND s.slug = ($3)::text AND season_visible(s, ($5)::uuid)
       AND s.slug <> ($2)::text
), added AS (
    INSERT INTO season_maps (season_id, map_id, players, rows, cols, size, terrain, hills, digest,
                             board, added_by)
    SELECT tgt.id, m.map_id, m.players, m.rows, m.cols, m.size, m.terrain, m.hills, m.digest,
           m.board, ($5)::uuid
      FROM tgt, src
      JOIN season_maps m ON m.season_id = src.id
     WHERE coalesce(jsonb_typeof(($4)::jsonb -> 'maps'), 'null') = 'null'
        OR m.map_id IN (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(($4)::jsonb -> 'maps') = 'array'
                                              THEN ($4)::jsonb -> 'maps' ELSE '[]'::jsonb END))
    ON CONFLICT DO NOTHING
 RETURNING map_id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($5)::uuid, 'map.import', 'season_map', added.map_id,
       jsonb_build_object('game', ($1)::text, 'season', ($2)::text, 'from', ($3)::text)
  FROM added
