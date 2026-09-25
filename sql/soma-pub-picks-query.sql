-- The pinned cards, in the order an admin set. A pick names a public match only, which the
-- pin checks; match_public is asked again here so a pick can never show more than the listing.
SELECT json_build_object(
        'game', g.slug,
        'picks', coalesce((SELECT json_agg(match_summary_json(m)
                                           || jsonb_build_object('pick_id', p.id, 'position', p.position)
                                           ORDER BY p.position, p.pinned_at)
                             FROM picks p
                             JOIN matches m ON m.id = p.match_id
                            WHERE p.unpinned_at IS NULL AND m.game_id = g.id AND match_public(m)),
                          '[]'::json)) AS body
  FROM games g
 WHERE g.slug = ($1)::text
