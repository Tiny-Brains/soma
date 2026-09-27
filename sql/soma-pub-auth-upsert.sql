WITH ident AS (
    SELECT user_id FROM identities WHERE provider = ($1)::text AND subject = ($2)::text
),
new_user AS (
    INSERT INTO users (handle, display_name, role)
    SELECT seed_handle(($3)::text, ($1)::text, ($2)::text), ($4)::text, 'competitor'
     WHERE NOT EXISTS (SELECT 1 FROM ident)
    RETURNING id
)
INSERT INTO identities (user_id, provider, subject, login)
SELECT coalesce((SELECT user_id FROM ident), (SELECT id FROM new_user)),
       ($1)::text, ($2)::text, ($3)::text
ON CONFLICT (provider, subject) DO UPDATE SET login = excluded.login
