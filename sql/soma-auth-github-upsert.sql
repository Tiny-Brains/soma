INSERT INTO users (github_id, handle, display_name, role)
VALUES (($1)::bigint, ($2)::text, ($3)::text, CASE
    WHEN ($1)::bigint::text = ANY (string_to_array(coalesce(($4)::text, ''), ',')) THEN 'admin'
    ELSE 'competitor'
    END::user_role)
ON CONFLICT (github_id) DO
UPDATE
SET handle = excluded.handle, role = CASE
WHEN excluded.role = 'admin' THEN excluded.role
ELSE users.role
END
