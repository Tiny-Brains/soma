SELECT mt.replay_key, match_detail_json(mt) AS body
FROM matches mt
WHERE mt.id = ($1)::uuid
AND (mt.trial_version_id IS NULL
    OR match_public(mt))
