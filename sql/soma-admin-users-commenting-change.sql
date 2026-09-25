-- SWITCH ONE ACCOUNT'S COMMENTING OFF OR ON, with its audit line. `$4` is the body as sent, because
-- `{"off": null}` (switch it on) and a body with no `off` at all must not read the same.
--   off: day | week | month | forever   needs a reason, which the author reads in the composer
--   off: null                           switches it back on, only if it is off now
-- An off already in force is replaced: the new term runs from now. A baseline is nobody's to switch.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), req AS (
    SELECT commenting_off_end(($4)::jsonb ->> 'off') AS until,
           nullif(btrim(coalesce(($4)::jsonb ->> 'reason', '')), '') AS reason,
           ($4)::jsonb ? 'off' AND jsonb_typeof(($4)::jsonb -> 'off') = 'null' AS switch_on,
           ($4)::jsonb ->> 'off' AS term
), changed AS (
    UPDATE users u
       SET comments_off_until  = req.until,
           comments_off_reason = CASE WHEN req.until IS NULL THEN NULL ELSE req.reason END
      FROM me, req
     WHERE u.id = try_uuid(($3)::text) AND u.role <> 'baseline'
       AND CASE WHEN req.switch_on THEN u.comments_off_until IS NOT NULL
                ELSE req.until IS NOT NULL AND req.reason IS NOT NULL AND char_length(req.reason) <= 300 END
    RETURNING u.handle, u.comments_off_until
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, reason, detail)
SELECT me.id, CASE WHEN c.comments_off_until IS NULL THEN 'user.commenting_on' ELSE 'user.commenting_off' END,
       'user', c.handle, req.reason, jsonb_build_object('until', c.comments_off_until, 'term', req.term)
  FROM changed c, me, req
