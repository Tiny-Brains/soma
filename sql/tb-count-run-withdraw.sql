UPDATE matches m
   SET status = 'cancelled', withdrawn_reason = 'SUPERSEDED',
       successor_version_id = ($2)::uuid, closed_at = now()
 WHERE m.status = 'pending'
   AND EXISTS (SELECT 1 FROM match_seats s WHERE s.match_id = m.id AND s.version_id = ($1)::uuid)
