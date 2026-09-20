SELECT (SELECT e ->> 'class'
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint
           -- classes.allow NARROWS the season's table: a class the season does not offer is not a
           -- landing place, so a model that measures into it finds no class and is refused. The
           -- word judge answers with is CLASS_NOT_OFFERED and not TOO_LARGE -- the model is not too
           -- large, this season simply is not running that class.
           AND season_admits_class(s, (e ->> 'class')::ladder)
         ORDER BY (e ->> 'max_bytes')::bigint
         LIMIT 1) AS cls,
       -- Whether ANY class of the season's full table would have fitted. It is what tells the two
       -- refusals apart: fits nothing at all is TOO_LARGE, fits something the season is not running
       -- is CLASS_NOT_OFFERED.
       (SELECT count(*) > 0
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint) AS fits_any
  FROM model_versions v
 WHERE v.id = ($1)::uuid
