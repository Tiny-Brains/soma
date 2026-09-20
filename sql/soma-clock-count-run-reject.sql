WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM fence
     WHERE c.key = 'roster' AND (SELECT count(*) FROM mark) >= 0
 RETURNING c.epoch
)
UPDATE model_versions v
   SET status = 'rejected', reject_reason = ($5)::text
  FROM bump
 WHERE v.id = ($4)::uuid AND v.status = 'verified'
