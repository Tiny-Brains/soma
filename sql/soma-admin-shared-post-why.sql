-- WHY A POST WAS NOT WRITTEN: whether the id names a post, and whether another post holds the
-- slug. Create and update both ask it; create passes the id it minted, which names none yet.
SELECT json_build_object(
    'found',      EXISTS (SELECT 1 FROM posts p WHERE p.id = ($1)::uuid),
    'slug_taken', EXISTS (SELECT 1 FROM posts p WHERE p.slug = ($2)::text AND p.id <> ($1)::uuid)) AS body
