-- A SEASON ADMIN'S SEND (S8), to the season's people (season_audience): the notify_sends row with
-- its count, one `broadcast` notification each keyed `notify:<send>`, and the audit line, in one
-- statement, as the platform's send is. The audience is recorded as {game, season, members}, which
-- is how the season's log finds its own sends. The caller is re-read as a live session; the
-- season-admin-only fragment already decided they may.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid
), wanted AS MATERIALIZED (
    SELECT a.user_id AS id FROM season_audience(($6)::uuid) a WHERE notification_wanted(a.user_id, 'season')
), sent AS (
    INSERT INTO notify_sends (id, subject, link, audience, sent_by, recipients)
    SELECT ($3)::uuid, btrim(($4)::text), nullif(btrim(coalesce(($5)::text, '')), ''),
           jsonb_build_object('game', ($7)::text, 'season', ($8)::text, 'members', true), me.id,
           (SELECT count(*) FROM wanted)
      FROM me
     WHERE line_ok(btrim(($4)::text), 200)
       AND (nullif(btrim(coalesce(($5)::text, '')), '') IS NULL OR site_path_ok(btrim(($5)::text)))
       AND EXISTS (SELECT 1 FROM wanted)
    ON CONFLICT (id) DO NOTHING
    RETURNING id, subject, link, recipients
), told AS (
    INSERT INTO notifications (user_id, category, kind, tone, subject, link, season, data, dedupe_key)
    SELECT w.id, 'season', 'broadcast', 'info', sent.subject, sent.link, ($8)::text,
           jsonb_build_object('send', sent.id), 'notify:' || sent.id
      FROM sent, wanted w
    ON CONFLICT (user_id, dedupe_key) DO NOTHING
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'notify.send', 'notify_send', sent.id::text,
       jsonb_build_object('recipients', sent.recipients, 'game', ($7)::text, 'season', ($8)::text)
  FROM sent, me
