-- live_runners is the outer FROM: a revoked key, a revoked runner or a demoted owner gets no row,
-- which the route answers 401, and a live idle runner gets {n: 0, items: []}. The roster is a CTE of
-- its own, so an empty one is still a row and the two cases stay apart.
--
-- THE SIGNATURE, ALWAYS; THE BODY ONLY WHEN IT MOVED. Every runner asks on every roster tick and the
-- answer rarely changes, so `sig` is an md5 over exactly what the body is built from -- the model
-- prefix, and each version's id, status, digest, key, manifest and order -- and $3 is the signature
-- of the copy the route already holds. Equal, and `body` is null: the route answers from its copy,
-- and this statement has read the rows and checked the runner, but built no JSON. Different (or no
-- copy), and it builds the body as before. The scalar subquery is evaluated only when CASE takes it.
--
-- The manifest is stored as text and every `::jsonb` parses it again, so it is parsed once a row
-- (`j.m`).
WITH runner AS (
    SELECT lr.id, lr.season_id
    FROM live_runners lr
    WHERE lr.id = ($2)::uuid ),
roster AS MATERIALIZED (
    SELECT v.id, v.status, v.weights_hash, v.artifact_key, v.manifest, v.created_at
    FROM runner lr
    JOIN model_versions v ON v.status IN ('verified', 'active')
        AND v.manifest IS NOT NULL
        AND v.artifact_key IS NOT NULL
        AND v.weights_hash IS NOT NULL
    -- ONLY THE SEASONS THIS KEY CAN BE ASKED TO PLAY (N30). A season key's roster is its own
    -- season's versions (and only while that season lets its own fleet play); a platform key's is
    -- every season the platform may play. A season runner's memory then holds its season's models
    -- alone.
    WHERE EXISTS (SELECT 1 FROM seasons se
        WHERE se.id = v.season_id
        AND CASE WHEN lr.season_id IS NOT NULL
                 THEN se.id = lr.season_id AND (se.fleet ->> 'matches') IN ('own', 'both')
                 ELSE (se.fleet ->> 'matches') IN ('platform', 'both')
            END)
    AND EXISTS (SELECT 1
        FROM match_seats s
        WHERE s.version_id = v.id) ),
sig AS (
    SELECT md5(($1)::text || '|' || coalesce(string_agg(concat_ws('|', r.id, r.status, r.weights_hash,
                r.artifact_key, md5(r.manifest), r.created_at), ',' ORDER BY r.created_at, r.id), '')) AS sig
    FROM roster r )
SELECT sig.sig, CASE
    WHEN sig.sig IS DISTINCT FROM ($3)::text THEN (SELECT json_build_object('n', count(*), 'items',
                coalesce(json_agg(json_build_object('model', ($1)::text || r.id::text, 'version_id', r.id,
                            'digest', r.weights_hash, 'key', r.artifact_key, 'manifest', jsonb_build_object(
                                'abi', j.m -> 'abi', 'name', to_jsonb(($1)::text || r.id::text), 'version',
                                coalesce(j.m -> 'version', '"1"'::jsonb), 'format', coalesce(j.m -> 'format',
                                    '"onnx"'::jsonb), 'description', coalesce(j.m -> 'description', '""'::jsonb),
                                'inputs', j.m -> 'inputs', 'outputs', j.m -> 'outputs', 'probe_dims',
                                coalesce(j.m -> 'probe_dims', '{}'::jsonb)), 'status', r.status)
                        ORDER BY r.created_at), '[]'::json))
        FROM roster r
        CROSS JOIN LATERAL (SELECT r.manifest::jsonb AS m) j)
    END AS body
FROM runner, sig
