-- THE VERSION AN ENTRY RE-ENTERS WITH (Q7): the entry's standing in the season it names (`from`) --
-- its active version there, or, when none stands, the newest it ever had in play -- with the bytes
-- it reuses (its own, or those it reused in turn, so a chain never forms). The caller's own entry
-- only, under a live session.
SELECT json_build_object('version_id', v.id, 'version', v.version, 'season', s.slug,
         'bytes_of', coalesce(v.bytes_of, v.id),
         'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash) AS body
  FROM models e
  JOIN games g         ON g.id = e.game_id
  JOIN seasons s       ON s.game_id = g.id AND s.slug = ($3)::text
  JOIN model_versions v ON v.model_id = e.id AND v.season_id = s.id
                       AND v.status IN ('active', 'superseded', 'disabled')
  JOIN live_sessions ls ON ls.sid = ($5)::uuid AND ls.user_id = e.owner_id
 WHERE e.id = try_uuid(($2)::text) AND e.owner_id = ($4)::uuid AND g.slug = ($1)::text
 ORDER BY (v.status = 'active') DESC, v.version DESC
 LIMIT 1
