-- The account's switch as it stands, and whether the body was one this route can act on: a term
-- commenting_off_end() knows with a reason, or `{"off": null}`.
WITH req AS (
    SELECT (commenting_off_end(($1)::jsonb ->> 'off') IS NOT NULL
            AND nullif(btrim(coalesce(($1)::jsonb ->> 'reason', '')), '') IS NOT NULL
            AND char_length(btrim(($1)::jsonb ->> 'reason')) <= 300)
           OR (($1)::jsonb ? 'off' AND jsonb_typeof(($1)::jsonb -> 'off') = 'null') AS ok
)
SELECT req.ok AS body_ok, u.role = 'baseline' AS baseline,
       json_build_object('id', u.id, 'handle', u.handle,
                         'commenting', CASE WHEN commenting_off_until(u) IS NULL THEN 'on' ELSE 'off' END,
                         'comments_off_until',  commenting_off_until(u),
                         'comments_off_reason', commenting_off_reason(u)) AS body
  FROM req
  LEFT JOIN users u ON u.id = try_uuid(($2)::text)
