-- THE PICTURE THE PROVIDER JUST SERVED, onto the account that identity belongs to.
--
-- ITS OWN STATEMENT, for the reason `promote` is one: two writes to `users` in a single statement
-- cannot see each other's rows, and this has to set a column on an account the upsert may have
-- created a moment earlier. After the upsert, so the identity row it joins through exists; before
-- the session is minted, so the first /v1/me of the new session already answers the new picture.
--
-- IT RUNS FOR A NEW ACCOUNT AND A RETURNING ONE ALIKE. The column is a display cache of the
-- identity this account LAST signed in with, so a competitor who changes their picture at the
-- provider, or signs in with a different one, carries that here on their next sign-in. A provider
-- that serves no picture clears it, which is the same rule read the other way.
--
-- avatar_ok() FILTERS, IT DOES NOT REFUSE: what it rejects is stored as NULL and drawn as initials.
-- A sign-in must never fail because a provider answered something unexpected -- which is also why
-- the workflow runs this continue_on_error.
UPDATE users u
   SET avatar_url = CASE WHEN avatar_ok(($3)::text) THEN ($3)::text END
  FROM identities i
 WHERE i.provider = ($1)::text
   AND i.subject = ($2)::text
   AND u.id = i.user_id
   AND u.avatar_url IS DISTINCT FROM CASE WHEN avatar_ok(($3)::text) THEN ($3)::text END
