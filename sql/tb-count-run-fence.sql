UPDATE clocks
   SET scheduled_for = ($1)::timestamptz, attempt = ($2)::int, updated_at = now()
 WHERE key = 'count'
   AND (scheduled_for, attempt) < (($1)::timestamptz, ($2)::int)
