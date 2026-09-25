-- WHO A SEND WOULD REACH: `audience` people, of whom `recipients` take the `season` category in
-- the app and are the ones a send writes to. Count and send ask notify_audience() the same way.
WITH who AS MATERIALIZED (
    SELECT a.user_id FROM notify_audience(($1)::jsonb) a
)
SELECT json_build_object(
    'valid',      notify_audience_ok(($1)::jsonb),
    'audience',   (SELECT count(*) FROM who),
    'recipients', (SELECT count(*) FROM who WHERE notification_wanted(who.user_id, 'season'))) AS body
