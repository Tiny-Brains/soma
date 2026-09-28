-- SHARED by a submission (POST /v1/submissions, $9 NULL) and a re-entry (POST /v1/submissions/reenter,
-- $9 the version whose bytes it reuses).
-- THE SEASON A SUBMISSION NAMES (N30). Seasons overlap, so "the open season of the game" is no
-- longer a single row: current_season(g.id, <slug>) resolves the named season, or the game's
-- featured public season when the slug is left out. The window predicates below still decide it is
-- open. The in-flight NOT EXISTS is PER SEASON (model_versions_one_in_flight_uniq is (model_id,
-- season_id)): a competitor may have a version in flight in class and another in public.
INSERT INTO model_versions (model_id, game_id, season_id, version, weights_hash, manifest_hash, note, bytes_of)
SELECT e.id, g.id, s.id, coalesce(max(v.version), 0) + 1, ($5)::text, ($6)::text, nullif(btrim(($7)::text),
    ''), ($9)::uuid
FROM games g
JOIN current_season(g.id, nullif(($8)::text, '')) s ON true
AND s.closed_at IS NULL
AND s.submissions_open_at <= now()
AND now() < s.submissions_close_at
JOIN models e ON e.game_id = g.id
AND e.owner_id = ($1)::uuid
AND e.retired_at IS NULL
AND e.id = ($3)::uuid
JOIN live_sessions ls ON ls.sid = ($4)::uuid
AND ls.user_id = ($1)::uuid
LEFT JOIN model_versions v ON v.model_id = e.id
WHERE g.slug = ($2)::text
AND season_admits(s, ($1)::uuid)
AND season_admits_entry(s, ($1)::uuid, e.id)
AND season_admits_weights(s, ($1)::uuid, ($5)::text, e.id)
AND season_admits_in_flight(s, ($1)::uuid)
AND season_admits_version(s, ($1)::uuid, e.id)
AND season_admits_cooldown(s, e.id)
AND text_hold_tag(($7)::text, false) IS NULL
-- A RE-ENTRY ($9) reuses the bytes of one of THIS entry's own versions, with the same weights: the
-- re-entry route read them from the entry's standing in an earlier season, and this repeats the
-- check, so no one's upload can be borrowed by naming its id. A submission passes NULL.
AND (($9)::uuid IS NULL OR EXISTS (SELECT 1 FROM model_versions b
                                   WHERE b.id = ($9)::uuid AND b.model_id = e.id
                                     AND b.weights_hash = ($5)::text AND b.manifest_hash = ($6)::text))
AND NOT EXISTS (SELECT 1
    FROM model_versions f
    WHERE f.model_id = e.id
    AND f.season_id = s.id
    AND f.status IN ('testing', 'verified'))
GROUP BY e.id, g.id, s.id
