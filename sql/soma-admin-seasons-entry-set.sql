-- NARROW A SEASON'S ENTRY, open -> restricted, BEFORE IT OPENS (BRD Q4, V1). Entry is the platform
-- admin's, set at creation beside visibility, and this is the one change either of them may take
-- afterwards. Everything the rule forbids is a predicate here rather than a guard, so a caller
-- arriving in the second a season opens cannot race it and `why` tells the four refusals apart:
--
--   `now() < s.submissions_open_at`   before open only. Once a season is open its entry is what
--                                     competitors have been reading and submitting against, and
--                                     narrowing it then would refuse people who were admitted.
--   `s.entry = 'open'`                narrowing only. restricted -> open would publish a cohort's
--                                     season to everyone, which is the half of Q4 that stays fixed;
--                                     it also makes this idempotent write nothing the second time.
--   `($3)::text = 'restricted'`       the only destination there is.
--
-- VISIBILITY IS NOT TOUCHED, and a private season cannot reach this statement: the table CHECK
-- holds private to restricted, so `s.entry = 'open'` is false for every private season and nothing
-- is written. That is the rule "visibility is fixed at creation" holding without a second clause.
--
-- The participants table is what `restricted` then means (P1): a season with no rows in it and
-- restricted entry admits nobody, which is exactly what it says, so narrowing before adding the
-- roster is allowed and is the ordinary order.
WITH updated AS (UPDATE seasons s
    SET entry = ($3)::text
    FROM games g
    WHERE g.id = s.game_id AND g.slug = ($1)::text AND s.slug = ($2)::text
    AND s.closed_at IS NULL
    AND now() < s.submissions_open_at
    AND s.entry = 'open'
    AND ($3)::text = 'restricted'
    RETURNING s.slug)
INSERT INTO audit_log (admin_id, action, target_kind, target_id, detail)
SELECT ($4)::uuid, 'season.entry', 'season', updated.slug,
       jsonb_build_object('game', ($1)::text, 'entry', ($3)::text)
FROM updated
