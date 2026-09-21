SELECT json_build_object(
         'n', count(*),
         'items', coalesce(json_agg(json_build_object(
                    'model_id', v.id,
                    'model', ($5)::text || v.id::text,
                    'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash,
                    'artifact_key', v.artifact_key,
                    'manifest_key', regexp_replace(v.artifact_key, 'model\.onnx$', 'manifest.json'),
                    -- STILL ARRIVING. The row is created by the POST that hands out the two
                    -- presigned PUTs, before either file exists, and no URL either upload route
                    -- signs outlives created_at + upload_window_s -- so a bucket that is missing
                    -- one is not a mistake of the competitor's until that window has passed. It is
                    -- what bounds the retry: this goes false on its own, and the verdict follows
                    -- when the clock's hold on the item lapses.
                    'uploading', v.created_at > now() - (($6)::int * interval '1 second'),
                    'budget_ops', coalesce((se.rules -> 'graph' ->> 'adapter_ops_max')::bigint,
                                           (g.manifest -> 'budgets' ->> 'adapter_ops_max')::bigint),
                    -- HOW MANY, NEVER THE SET: the reference set is ~500 KB of JSON, and every copy a
                    -- workflow makes of it is kept twice over (the audit trail, then the trace). The
                    -- runner is sent it by the gate's claim, straight from `games`.
                    'observations_n', CASE WHEN jsonb_typeof(g.reference_observations) = 'array'
                                           THEN jsonb_array_length(g.reference_observations)
                                           ELSE 0 END,
                    -- THE SEASON'S GRAPH RULES, CARRIED PER ITEM, from THE VERSION'S OWN SEASON, so a
                    -- version is judged by the rules it was submitted under rather than the live
                    -- season's.
                    'opset_min', coalesce((se.rules -> 'graph' ->> 'opset_min')::int, ($2)::int),
                    'opset_max', coalesce((se.rules -> 'graph' ->> 'opset_max')::int, ($3)::int),
                    'op_allowlist', coalesce(
                        -- INTERSECTED with the platform's list, never replacing it: a season that
                        -- allowed an operator this runtime cannot execute would admit a model that
                        -- then fails at play. A season may only narrow.
                        (SELECT jsonb_agg(o) FROM jsonb_array_elements_text(($4)::jsonb) AS o
                          WHERE o IN (SELECT jsonb_array_elements_text(
                                          se.rules -> 'graph' -> 'op_allowlist'))),
                        ($4)::jsonb),
                    'params_max',   (se.rules -> 'graph' ->> 'params_max')::bigint,
                    'infer_us_max', (se.rules -> 'graph' ->> 'infer_us_max')::bigint,
                    -- What judge tests to know the rules reached it at all. Without it a null
                    -- ceiling reads as "no ceiling" through `{"<": [x, null]}`, which is FALSY --
                    -- so every submission would pass every gate, silently.
                    'rules_ok', se.id IS NOT NULL,
                    -- THE RUNNER'S REPORT, TYPED. Null until one has landed, which is what sends the
                    -- item down the prepare path. Never the raw JSON: see admission_facts().
                    'job', (SELECT admission_facts(a) FROM admissions a WHERE a.version_id = v.id),
                    -- A SLOW PROBE'S MEASUREMENT, in microseconds: the median Orion names in its
                    -- refusal ("took 347.532 ms (median of 5), over models.max_probe_ms"). requeue
                    -- keeps it on the version, so a submission that expires PROBE_TOO_SLOW says how
                    -- slow. Null for every other report, and for one whose wording has moved.
                    'probe_us', (SELECT round(substring(a.report #>> '{admission,reason}'
                                                        FROM 'took ([0-9]+(\.[0-9]+)?) ms')::numeric
                                              * 1000)::bigint
                                   FROM admissions a
                                  WHERE a.version_id = v.id
                                    AND a.report #>> '{admission,stage}' = 'probe'
                                    AND position('models.max_probe_ms'
                                                 IN a.report #>> '{admission,reason}') > 0))
                  ORDER BY v.created_at), '[]'::json)) AS body
  FROM model_versions v
  JOIN games g   ON g.id = v.game_id
  JOIN seasons se ON se.id = v.season_id
 WHERE v.admit_token = ($1)::uuid AND v.status = 'testing'
