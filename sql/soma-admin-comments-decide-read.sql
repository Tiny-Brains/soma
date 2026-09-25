-- Each named comment as it stands now, decided here or not.
SELECT json_build_object(
    'action', ($2)::text,
    'comments', coalesce(json_agg(json_build_object('id', c.id, 'state', c.state,
                                                    'decided_at', c.decided_at) ORDER BY c.id), '[]'::json)) AS body
  FROM comments c
 WHERE c.id IN (SELECT jsonb_uuids(($1)::jsonb))
