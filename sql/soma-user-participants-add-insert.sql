-- BULK ADD (N30). The logins arrive as a JSON array or one comma-separated string (a textarea), and
-- each becomes a season_participants row for the season the fragment resolved ($1), under the given
-- provider ($2, any provider slug, 'github' by default). A login already matching ONE identity of that
-- provider is PINNED to its account now; one that is not is kept as a login and pinned at that
-- identity's next sign-in -- so a member listed before they
-- sign in is admitted the moment they do, without an edit. A login already live in the season is left
-- as it is (ON CONFLICT DO NOTHING on the one-live partial index); a previously removed one is
-- re-added as a fresh row. One audit line names the whole batch.
WITH given AS (
    -- Bound as TEXT so both forms work: a JSON array (Orion serialises it to `["a","b"]`) and a
    -- textarea (one per line or comma-separated). A leading `[` marks the array; else split on
    -- commas and newlines.
    SELECT DISTINCT btrim(h) AS login
    FROM unnest(CASE
        WHEN left(btrim(($3)::text), 1) = '[' THEN ARRAY(SELECT jsonb_array_elements_text(($3)::text::jsonb))
        ELSE regexp_split_to_array(($3)::text, '[,\n]+')
        END) AS h
    WHERE btrim(h) <> ''
), prov AS (
    SELECT coalesce(nullif(($2)::text, ''), 'github') AS provider
), resolved AS (
    -- Pinned now only when exactly ONE account holds the login on that provider: two (a login freed
    -- and taken again, both identities still on file) is not a choice to make here, so the row stays
    -- a login and the next sign-in of it pins it (soma-pub-auth-pin).
    SELECT given.login,
           (SELECT min(i.user_id::text)::uuid FROM identities i, prov
             WHERE i.provider = prov.provider
               AND lower(i.login) = lower(given.login)
            HAVING count(DISTINCT i.user_id) = 1) AS user_id
    FROM given
), ins AS (
    INSERT INTO season_participants (season_id, provider, login, user_id, added_by)
    SELECT ($1)::uuid, prov.provider, resolved.login, resolved.user_id, ($4)::uuid
    FROM resolved, prov
    ON CONFLICT (season_id, provider, lower(login)) WHERE removed_at IS NULL DO NOTHING
    RETURNING id
)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'participant.add', 'season', (SELECT slug FROM seasons WHERE id = ($1)::uuid),
       jsonb_build_object('provider', (SELECT provider FROM prov),
                          'added', (SELECT count(*) FROM ins),
                          'logins', (SELECT jsonb_agg(login ORDER BY login) FROM given))
WHERE EXISTS (SELECT 1 FROM given)
