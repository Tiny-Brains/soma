-- A model (entry) by id, with its public versions. An entry is per game but its versions are per
-- season, so the version list is gated to PUBLIC seasons (N30/V3): a private season's versions --
-- their ratings, sizes and status -- show only to that season's viewers, never on this anonymous
-- read. A model whose only versions are in a private season shows with an empty list.
SELECT json_build_object( 'model_id', e.id, 'model', e.name, 'owner', e.owner_id, 'owner_handle',
        u.handle, 'baseline', u.role = 'baseline', 'game', g.slug, 'created_at', e.created_at, 'retired',
        e.retired_at IS NOT NULL, 'retired_at', e.retired_at, 'versions', coalesce((SELECT json_agg(version_json(v,
                    ($2)::float8)
                ORDER BY v.version DESC)
            FROM model_versions v
            WHERE v.model_id = e.id
            AND version_public(v.status)
            AND EXISTS (SELECT 1 FROM seasons s WHERE s.id = v.season_id AND s.visibility = 'public')), '[]'::json)) AS body
FROM models e
JOIN users u ON u.id = e.owner_id
JOIN games g ON g.id = e.game_id
WHERE e.id = ($1)::uuid
