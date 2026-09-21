INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, data, dedupe_key)
SELECT e.owner_id, 'submissions',
       CASE v.status WHEN 'rejected' THEN 'alert' ELSE 'progress' END,
       CASE v.status WHEN 'verified' THEN 'info' WHEN 'active' THEN 'ok' ELSE 'bad' END,
       e.name || ' v' || v.version ||
         CASE WHEN v.status = 'verified'             THEN ' was admitted'
              WHEN v.status = 'active'               THEN ' passed its trial'
              WHEN v.reject_reason = 'SEASON_CLOSED' THEN ' was withdrawn when its season closed'
              WHEN v.weight_class IS NULL            THEN ' was rejected'
              ELSE                                        ' failed its trial' END,
       -- The rejection's description IS its reason word, as the book spells it; the page
       -- that explains the words is the book's, and a second explanation here would drift from it.
       CASE WHEN v.status = 'verified'
            THEN 'Admitted as ' || v.weight_class || ' at '
                 || to_char(v.size_bytes, 'FM999,999,999,990') || ' bytes. Its trial match is next.'
            WHEN v.status = 'active'
            THEN 'It is on the ' || v.weight_class || ' and open ladders.'
            ELSE v.reject_reason END,
       '/models/' || e.id || '/v' || v.version,
       g.slug, se.slug, e.id, v.id,
       jsonb_strip_nulls(jsonb_build_object(
           'model', e.name, 'version', v.version, 'status', v.status,
           'stage', CASE WHEN v.status = 'verified'             THEN 'admission'
                         WHEN v.status = 'active'               THEN 'trial'
                         WHEN v.reject_reason = 'SEASON_CLOSED' THEN 'season'
                         WHEN v.weight_class IS NULL            THEN 'admission'
                         ELSE                                        'trial' END,
           'class', v.weight_class, 'size_bytes', v.size_bytes, 'params', v.param_count,
           'infer_us', v.infer_us, 'reason_code', v.reject_reason)),
       'version:' || v.id || ':' || v.status
  FROM model_versions v
  JOIN models e   ON e.id = v.model_id
  JOIN games g    ON g.id = v.game_id
  JOIN seasons se ON se.id = v.season_id
 WHERE v.admit_token = ($1)::uuid AND v.reject_reason IN ('TIMED_OUT', 'PROBE_TOO_SLOW')
   AND v.status IN ('verified', 'active', 'rejected')
   AND notification_wanted(e.owner_id, 'submissions')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
