-- ONE STATEMENT SENDS: the notify_sends row with its recipient count, a notifications row per
-- recipient keyed `notify:<send>`, and the audit line. notification_wanted() is asked once per
-- person, in `wanted`, and the same set is counted and written. A retried send with the same id
-- writes nothing twice.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), aud AS (
    SELECT ($6)::jsonb AS a, notify_audience_ok(($6)::jsonb) AS valid
), who AS (
    SELECT a.user_id AS id FROM notify_audience(($6)::jsonb) a
), wanted AS MATERIALIZED (
    SELECT who.id FROM who WHERE notification_wanted(who.id, 'season')
), sent AS (
    INSERT INTO notify_sends (id, subject, link, audience, sent_by, recipients)
    SELECT ($3)::uuid, btrim(($4)::text), nullif(btrim(coalesce(($5)::text, '')), ''), aud.a, me.id,
           (SELECT count(*) FROM wanted)
      FROM me, aud
     WHERE aud.valid
       AND line_ok(btrim(($4)::text), 200)
       AND (nullif(btrim(coalesce(($5)::text, '')), '') IS NULL OR site_path_ok(btrim(($5)::text)))
       AND EXISTS (SELECT 1 FROM wanted)
    ON CONFLICT (id) DO NOTHING
    RETURNING id, subject, link, recipients
), told AS (
    INSERT INTO notifications (user_id, category, kind, tone, subject, link, data, dedupe_key)
    SELECT w.id, 'season', 'broadcast', 'info', sent.subject, sent.link,
           jsonb_build_object('send', sent.id), 'notify:' || sent.id
      FROM sent, wanted w
    ON CONFLICT (user_id, dedupe_key) DO NOTHING
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'notify.send', 'notify_send', sent.id::text,
       jsonb_build_object('recipients', sent.recipients, 'audience', ($6)::jsonb)
  FROM sent, me
