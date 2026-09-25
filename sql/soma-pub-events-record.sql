-- One watch event, counted per day and never per person, on a random shard of its key so a day's
-- visits never queue on one row. A match event names a PUBLIC match or writes nothing, and a
-- malformed id is try_uuid()'s NULL -- a no-op, not a 500.
INSERT INTO watch_events (match_id, day, event, via, shard)
SELECT t.match_id, current_date, ($1)::text, ($3)::text, floor(random() * 16)::smallint
  FROM (SELECT NULL::uuid AS match_id
         WHERE ($1)::text = 'visit'
        UNION ALL
        SELECT m.id
          FROM matches m
         WHERE ($1)::text <> 'visit'
           AND m.id = try_uuid(($2)::text)
           AND match_public(m)) t
ON CONFLICT ON CONSTRAINT watch_events_key DO UPDATE SET n = watch_events.n + 1
