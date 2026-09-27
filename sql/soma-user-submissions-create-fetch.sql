-- WHAT IS LEFT OF THE WINDOW, not a fresh one. The admit clock gives a version upload_window_s from
-- created_at to arrive, so a re-mint's URLs expire when that does: a URL good past it is an upload
-- the clock has already given up on. The minutes round down, so the response never promises time
-- the version does not have.
SELECT json_build_object('version_id', v.id, 'model_id', e.id, 'model', e.name, 'version', v.version,
        'status', v.status, 'season', se.slug, 'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash)
    AS body, w.s AS upload_s, CASE
    WHEN w.s >= 60 THEN (w.s / 60) || 'm'
    ELSE w.s || 's'
    END AS upload_expires_in
FROM model_versions v
CROSS JOIN LATERAL (SELECT greatest(1, ($6)::int - floor(extract(epoch FROM now() - v.created_at))::int) AS s) w
JOIN models e ON e.id = v.model_id
JOIN games g ON g.id = e.game_id
-- The version's season must be the one the submission named (or the featured public one). The same
-- weights may now be testing in two seasons (C3), so keying on (owner, game, model, weights) alone
-- is ambiguous; current_season(g.id, <slug>) pins which one the re-mint answers for.
JOIN current_season(g.id, nullif(($7)::text, '')) se ON se.id = v.season_id
JOIN live_sessions s ON s.sid = ($4)::uuid
AND s.user_id = e.owner_id
WHERE e.owner_id = ($1)::uuid
AND g.slug = ($2)::text
AND e.id = ($3)::uuid
AND v.status = 'testing'
AND v.weights_hash = ($5)::text
