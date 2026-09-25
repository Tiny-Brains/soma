-- ONE USER'S DESK, by id or handle: the account and its commenting switch, its sign-ins (an admin
-- route may read sessions; a clock may not), its models with their versions, its recent comments in
-- every state, the reports filed against them, and every audit line about the account or one of its
-- comments -- the switch's history among them. Each list is bounded.
WITH me AS (
    SELECT u.id FROM live_sessions ls JOIN users u ON u.id = ls.user_id AND u.role = 'admin'
     WHERE ls.sid = ($2)::uuid AND ls.user_id = ($1)::uuid
), who AS (
    SELECT u.* FROM users u
     WHERE u.id = try_uuid(($3)::text) OR lower(u.handle) = lower(($3)::text)
), mine AS (
    SELECT c.* FROM who JOIN comments c ON c.author_id = who.id
     ORDER BY c.created_at DESC LIMIT 50
)
SELECT json_build_object(
    'user', json_build_object(
        'id', who.id, 'handle', who.handle, 'display_name', who.display_name, 'role', who.role,
        'bio', who.bio, 'created_at', who.created_at,
        'commenting', CASE WHEN commenting_off_until(wu) IS NULL THEN 'on' ELSE 'off' END,
        'comments_off_until',  commenting_off_until(wu),
        'comments_off_reason', commenting_off_reason(wu)),
    'counts', (SELECT json_build_object(
                   'live',     count(*) FILTER (WHERE c.state = 'live'),
                   'held',     count(*) FILTER (WHERE c.state = 'held'),
                   'removed',  count(*) FILTER (WHERE c.state = 'removed'),
                   'deleted',  count(*) FILTER (WHERE c.state = 'deleted'),
                   'reported', count(*) FILTER (WHERE EXISTS (SELECT 1 FROM comment_reports r
                                                               WHERE r.comment_id = c.id)))
                 FROM comments c WHERE c.author_id = who.id),
    'sessions', coalesce((SELECT json_agg(json_build_object(
                    'issued_at', s.issued_at, 'last_seen_at', s.last_seen_at, 'expires_at', s.expires_at,
                    'revoked_at', s.revoked_at, 'user_agent', s.user_agent,
                    'live', s.revoked_at IS NULL AND s.expires_at > now()) ORDER BY s.last_seen_at DESC)
                    FROM (SELECT * FROM sessions s WHERE s.user_id = who.id
                           ORDER BY s.last_seen_at DESC LIMIT 20) s), '[]'::json),
    'models', coalesce((SELECT json_agg(json_build_object(
                  'model_id', e.id, 'model', e.name, 'game', g.slug, 'retired', e.retired_at IS NOT NULL,
                  'versions', (SELECT coalesce(json_agg(json_build_object(
                                   'version_id', v.id, 'version', v.version, 'status', v.status,
                                   'class', v.weight_class, 'season', se.slug, 'created_at', v.created_at)
                                   ORDER BY v.version DESC), '[]'::json)
                                 FROM model_versions v JOIN seasons se ON se.id = v.season_id
                                WHERE v.model_id = e.id)) ORDER BY e.name)
                  FROM models e JOIN games g ON g.id = e.game_id
                 WHERE e.owner_id = who.id), '[]'::json),
    'comments', coalesce((SELECT json_agg(json_build_object(
                    'id', c.id, 'state', c.state, 'hold_tag', c.hold_tag, 'body', c.body,
                    'created_at', c.created_at, 'decided_at', c.decided_at,
                    'host', thread_host(t),
                    'host_id', thread_host_id(t),
                    'reports', (SELECT count(*) FROM comment_reports r WHERE r.comment_id = c.id))
                    ORDER BY c.created_at DESC)
                    FROM mine c JOIN threads t ON t.id = c.thread_id), '[]'::json),
    'reports', coalesce((SELECT json_agg(json_build_object(
                   'comment_id', r.comment_id, 'reporter', ru.handle, 'reason', r.reason,
                   'words', r.words, 'at', r.created_at) ORDER BY r.created_at DESC)
                   FROM (SELECT r.* FROM comment_reports r JOIN comments c ON c.id = r.comment_id
                          WHERE c.author_id = who.id ORDER BY r.created_at DESC LIMIT 50) r
                   JOIN users ru ON ru.id = r.reporter_id), '[]'::json),
    'audit', coalesce((SELECT json_agg(json_build_object(
                 'id', a.id, 'at', a.at, 'admin', au.handle, 'action', a.action,
                 'target_kind', a.target_kind, 'target_id', a.target_id, 'reason', a.reason,
                 'detail', a.detail) ORDER BY a.at DESC, a.id DESC)
                 FROM (SELECT a.* FROM audit_log a
                        WHERE (a.target_kind = 'user' AND a.target_id = who.handle)
                           OR (a.target_kind = 'comment'
                               AND a.target_id IN (SELECT c.id::text FROM comments c WHERE c.author_id = who.id))
                        ORDER BY a.at DESC, a.id DESC LIMIT 50) a
                 JOIN users au ON au.id = a.admin_id), '[]'::json)) AS body
  FROM me
  JOIN who ON true
  JOIN users wu ON wu.id = who.id
