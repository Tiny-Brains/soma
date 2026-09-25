SELECT json_build_object(
    'found',  EXISTS (SELECT 1 FROM matches m WHERE m.id = try_uuid(($1)::text)),
    'public', coalesce((SELECT match_public(m) FROM matches m WHERE m.id = try_uuid(($1)::text)), false)) AS body
