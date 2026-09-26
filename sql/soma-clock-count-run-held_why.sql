-- WHY THE FOLD MOVED NOTHING, read only when it did. `mine` is whether this occurrence still holds
-- the fence: false is the one reason to halt the run. `unfoldable` is the other cause: the row is
-- still `finished` under a live fence, so the posterior the plugin produced did not cover every
-- (seat, ladder) the row has. That row would head the batch every tick for ever, so the clock logs
-- it and goes on to the next item rather than halting on it.
SELECT EXISTS (SELECT 1 FROM clocks
                WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int) AS mine,
       coalesce((SELECT m.status = 'finished' FROM matches m WHERE m.id = ($3)::uuid), false) AS unfoldable
