-- THE TWO LISTS A CREATE CARRIES, checked before anything is written: `providers` (null, or an
-- array of provider slugs: season_providers_ok(), the table CHECK's own function) and `admins`
-- (null, or an array of handles, every one an account that is not a baseline). An unknown handle
-- is named back, so the admin sees which one to fix, rather than a season created without it. $1
-- is the whole request, an object: either list bound on its own would reach the cast as raw text
-- when it is a string, and fail the bind with Orion's message rather than this statement's answer.
WITH req AS (
    SELECT nullif(($1)::jsonb -> 'providers', 'null'::jsonb) AS providers,
           nullif(($1)::jsonb -> 'admins', 'null'::jsonb)    AS admins
)
SELECT json_build_object(
         'providers_ok', season_providers_ok(req.providers),
         'admins_ok',    CASE WHEN req.admins IS NULL THEN true
                              WHEN jsonb_typeof(req.admins) <> 'array' THEN false
                              ELSE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(req.admins) e
                                                WHERE jsonb_typeof(e) <> 'string' OR btrim(e #>> '{}') = '') END,
         'unknown',      CASE WHEN jsonb_typeof(req.admins) = 'array'
                              THEN (SELECT coalesce(json_agg(btrim(e #>> '{}')), '[]'::json)
                                      FROM jsonb_array_elements(req.admins) e
                                     WHERE jsonb_typeof(e) = 'string' AND btrim(e #>> '{}') <> ''
                                       AND NOT EXISTS (SELECT 1 FROM users u
                                                        WHERE lower(u.handle) = lower(btrim(e #>> '{}'))
                                                          AND u.role <> 'baseline'))
                              ELSE '[]'::json END) AS body
  FROM req
