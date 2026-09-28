-- Why an import brought nothing: the season is gone or closed, or the source is unknown, the same
-- season, or one the caller may not see; or the list ($6 names the field of the request, $5) is
-- there and not an array -- else everything it holds is already here.
SELECT json_build_object(
         'target', (SELECT json_build_object('closed', s.closed_at IS NOT NULL)
                      FROM seasons s JOIN games g ON g.id = s.game_id
                     WHERE g.slug = ($1)::text AND s.slug = ($2)::text),
         'source', EXISTS (SELECT 1 FROM seasons s JOIN games g ON g.id = s.game_id
                            WHERE g.slug = ($1)::text AND s.slug = ($3)::text
                              AND season_visible(s, ($4)::uuid) AND s.slug <> ($2)::text),
         'list_ok', coalesce(jsonb_typeof(($5)::jsonb -> ($6)::text), 'null') IN ('null', 'array')) AS body
