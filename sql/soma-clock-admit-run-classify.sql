SELECT c.e ->> 'class' AS cls,
       -- Whether ANY class of the season's full table would have fitted. It is what tells the two
       -- refusals apart: fits nothing at all is TOO_LARGE, fits something the season is not running
       -- is CLASS_NOT_OFFERED.
       (SELECT count(*) > 0
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint) AS fits_any,
       -- THE MEMORY, PRICED AGAINST THE CLASS IT LANDS IN, from the registration the runner was
       -- given (its outputs are the manifest's) and the game's board envelope. memory_price() is
       -- the whole rule. No verdict and no bytes for a class that allows memory means the game
       -- declares no envelope, which is ours: judge retries it.
       p.verdict AS memory_refused,
       p.bytes_max AS memory_bytes,
       c.e IS NOT NULL AND p.verdict IS NULL AND p.bytes_max IS NULL AS memory_unpriced
  FROM model_versions v
  JOIN games g ON g.id = v.game_id
  LEFT JOIN admissions a ON a.version_id = v.id
  LEFT JOIN LATERAL (
        SELECT e
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint
           -- classes.allow NARROWS the season's table: a class the season does not offer is not a
           -- landing place, so a model that measures into it finds no class and is refused. The
           -- word judge answers with is CLASS_NOT_OFFERED and not TOO_LARGE -- the model is not too
           -- large, this season simply is not running that class.
           AND season_admits_class(s, (e ->> 'class')::ladder)
         ORDER BY (e ->> 'max_bytes')::bigint
         LIMIT 1) c ON true
  LEFT JOIN LATERAL memory_price(a.registration, g.manifest #> '{limits,boards}', c.e) p ON true
 WHERE v.id = ($1)::uuid
