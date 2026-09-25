-- Pinned last, and its audit line. A pick names a public match only, and one match holds
-- one live pick: picks_live_uniq is the arbiter.
WITH me AS (
    SELECT u.id
      FROM live_sessions ls
      JOIN users u ON u.id = ls.user_id
     WHERE ls.sid = ($2)::uuid AND u.id = ($1)::uuid AND u.role = 'admin'
), pinned AS (
    INSERT INTO picks (match_id, position, pinned_by)
    SELECT m.id, coalesce((SELECT max(p.position) FROM picks p WHERE p.unpinned_at IS NULL), 0) + 1, me.id
      FROM me, matches m
     WHERE m.id = try_uuid(($3)::text) AND match_public(m)
    ON CONFLICT (match_id) WHERE unpinned_at IS NULL DO NOTHING
    RETURNING id, match_id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT me.id, 'pick.pin', 'match', pinned.match_id::text, jsonb_build_object('pick', pinned.id)
  FROM pinned, me
