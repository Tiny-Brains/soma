-- ONE SEASON'S AUDIT LOG, for its season admins and platform admins (S7): every admin line about
-- the season -- its creation, window, rules, fleet, fill, rounds, boards, baselines, participants,
-- admins, keys and runners -- newest first, fifty a page, keyset on (at, id) down
-- audit_log_season_idx. `action` narrows by prefix, as on the platform's audit page.
WITH page AS (
    SELECT a.*
      FROM audit_log a
     WHERE a.season_id = ($1)::uuid
       AND (nullif(btrim(coalesce(($2)::text, '')), '') IS NULL
            OR left(a.action, char_length(btrim(($2)::text))) = btrim(($2)::text))
       AND (($3)::text IS NULL
            OR (a.at, a.id) < (split_part(($3)::text, '|', 1)::timestamptz,
                               try_uuid(split_part(($3)::text, '|', 2))))
     ORDER BY a.at DESC, a.id DESC
     LIMIT 50
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
