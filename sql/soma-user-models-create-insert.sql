-- CREATE AN ENTRY. An entry (`models`) is per owner and game, and NOTHING here is per season (N30/
-- C1): naming a model costs nothing and reaches no season, so this no longer joins a season or asks
-- season_admits/season_admits_entry -- which is also what makes it correct under overlap, where a
-- join to "the live season" matched every open season and tried to write a row per one. Participation
-- and the per-season entry cap are the SUBMISSION's to enforce (season_admits, season_admits_entry).
-- Written only when the game exists, the session is live, and the name is non-empty, within length,
-- and not already this owner's for this game.
INSERT INTO models (owner_id, game_id, name)
SELECT ($1)::uuid, g.id, btrim(($3)::text)
FROM games g
JOIN live_sessions ls ON ls.sid = ($4)::uuid
AND ls.user_id = ($1)::uuid
WHERE g.slug = ($2)::text
AND btrim(($3)::text) <> ''
AND length(btrim(($3)::text)) <= 64
AND NOT EXISTS (SELECT 1
    FROM models e
    WHERE e.owner_id = ($1)::uuid
    AND e.game_id = g.id
    AND lower(e.name) = lower(btrim(($3)::text)))
