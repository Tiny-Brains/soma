-- THE AUDIT LOG, newest first, fifty a page, keyset on (at, id) down audit_log_at_idx -- or
-- audit_log_admin_idx when `admin` names one handle, in a branch of its own. `action` narrows by prefix (`comment.` or
-- `comment.remove`); `q` is a substring of the target or the reason. Read-only: nothing here acts.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), f AS (
    SELECT (SELECT u.id FROM users u WHERE lower(u.handle) = lower(nullif(btrim(coalesce(($3)::text, '')), '')))
               AS admin_id,
           nullif(btrim(coalesce(($3)::text, '')), '') IS NOT NULL AS by_admin,
           nullif(btrim(coalesce(($4)::text, '')), '') AS action,
           nullif(lower(btrim(coalesce(($5)::text, ''))), '') AS q
), matched AS NOT MATERIALIZED (
    SELECT a.*
      FROM audit_log a, f
     WHERE (f.action IS NULL OR left(a.action, char_length(f.action)) = f.action)
       AND (f.q IS NULL OR strpos(lower(coalesce(a.target_id, '')), f.q) > 0
            OR strpos(lower(coalesce(a.reason, '')), f.q) > 0)
       AND (($6)::text IS NULL
            OR (a.at, a.id) < (split_part(($6)::text, '|', 1)::timestamptz,
                               try_uuid(split_part(($6)::text, '|', 2))))
), page AS (
    -- Two branches, so each reads its own index: one admin's lines down audit_log_admin_idx, or
    -- every line down audit_log_at_idx. Only one of them has rows.
    (SELECT m.* FROM matched m, f
      WHERE f.by_admin AND m.admin_id = f.admin_id
      ORDER BY m.at DESC, m.id DESC LIMIT 50)
    UNION ALL
    (SELECT m.* FROM matched m, f
      WHERE NOT f.by_admin
      ORDER BY m.at DESC, m.id DESC LIMIT 50)
)
SELECT json_build_object(
    'entries', coalesce((SELECT json_agg(json_build_object(
                   'id', p.id, 'at', p.at, 'admin', u.handle, 'action', p.action,
                   'target_kind', p.target_kind, 'target_id', p.target_id, 'reason', p.reason,
                   'detail', p.detail) ORDER BY p.at DESC, p.id DESC)
                   FROM page p JOIN users u ON u.id = p.admin_id), '[]'::json),
    'next_cursor', CASE WHEN (SELECT count(*) FROM page) = 50
                        THEN (SELECT (to_json(p.at) #>> '{}') || '|' || p.id::text
                                FROM page p ORDER BY p.at, p.id LIMIT 1) END) AS body
  FROM me
