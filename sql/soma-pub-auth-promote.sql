UPDATE users SET role = 'admin'
 WHERE id = (SELECT user_id FROM identities
              WHERE provider = ($1)::text AND subject = ($2)::text)
   AND role = 'competitor'
   AND (($1)::text || ':' || ($2)::text)
       = ANY (string_to_array(coalesce(($3)::text, ''), ','))
