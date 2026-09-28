-- PIN THE INVITES WAITING FOR THIS LOGIN (S3). A participant row added before its account existed
-- carries only a provider and a login; the first sign-in of an identity with that provider and login
-- pins every such live row to the account, so from then on the row admits that account alone, and a
-- login later freed or renamed on the provider cannot hand the seat to whoever holds it next. A row
-- already pinned is never moved.
UPDATE season_participants sp
   SET user_id = i.user_id
  FROM identities i
 WHERE i.provider = ($1)::text AND i.subject = ($2)::text
   AND sp.user_id IS NULL AND sp.removed_at IS NULL AND sp.login IS NOT NULL
   AND sp.provider = i.provider AND lower(sp.login) = lower(($3)::text)
