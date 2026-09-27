-- A season's live participants, wildcards first then by login. `resolved` is whether the login has
-- been matched to an account yet (pinned user_id): a listed member who has not signed in is `waiting`
-- until they do, which is normal for a cohort written before the term. `handle` is the resolved
-- account's platform handle, for the desk to show a face beside a login. The season id comes from the
-- season-admin-only fragment, which already resolved {game}/{slug} and refused an unknown one.
SELECT json_build_object(
    'season', se.slug,
    'participants', coalesce((SELECT json_agg(json_build_object(
                'id',        sp.id,
                'provider',  sp.provider,
                'login',     sp.login,
                'wildcard',  sp.login IS NULL,
                'user_id',   sp.user_id,
                'handle',    u.handle,
                'resolved',  sp.user_id IS NOT NULL,
                'added_at',  sp.added_at)
            ORDER BY (sp.login IS NULL) DESC, lower(sp.login), sp.added_at)
        FROM season_participants sp
        LEFT JOIN users u ON u.id = sp.user_id
        WHERE sp.season_id = se.id AND sp.removed_at IS NULL), '[]'::json)) AS body
FROM seasons se
WHERE se.id = ($1)::uuid
