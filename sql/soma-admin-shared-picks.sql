-- THE LIVE PICKS, in order: the desk's list and the answer to every pick write. Each is the card
-- GET /v1/games/{game}/picks returns, with who pinned it and when beside `pick_id` and `position`.
SELECT json_build_object('picks', coalesce(json_agg(
           match_summary_json(m) || jsonb_build_object('pick_id', p.id, 'position', p.position,
                                                       'pinned_by', u.handle, 'pinned_at', p.pinned_at)
           ORDER BY p.position, p.pinned_at, p.id), '[]'::json)) AS body
  FROM picks p
  JOIN matches m ON m.id = p.match_id
  JOIN users u   ON u.id = p.pinned_by
 WHERE p.unpinned_at IS NULL
