-- Published at once, and its audit line. The predicates ask the table CHECKs' own functions, plus
-- an end time still ahead, so a bad field writes nothing rather than failing. `kind` is the
-- workflow's refusal and the CHECK's.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), made AS (
    INSERT INTO announcements (id, kind, body, link, dismissable, ends_at, published_by)
    SELECT ($3)::uuid, ($4)::text, btrim(($5)::text), nullif(btrim(coalesce(($6)::text, '')), ''),
           coalesce(($7)::boolean, true), ($8)::timestamptz, me.id
      FROM me
     WHERE line_ok(btrim(($5)::text), 200)
       AND (nullif(btrim(coalesce(($6)::text, '')), '') IS NULL OR link_ok(btrim(($6)::text)))
       AND (($8)::timestamptz IS NULL OR ($8)::timestamptz > now())
    ON CONFLICT DO NOTHING
    RETURNING id, kind
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'announcement.publish', 'announcement', made.id::text, jsonb_build_object('kind', made.kind)
  FROM made, me
