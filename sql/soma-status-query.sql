SELECT json_build_object( 'checked_at', now(), 'arena', json_build_object( 'matches_last_hour', (SELECT
                count(*)
            FROM matches
            WHERE played_at > now() - interval '1 hour'), 'queue', (SELECT count(*)
            FROM matches
            WHERE status = 'pending'), 'in_flight', (SELECT count(*)
            FROM matches
            WHERE status IN ('claimed', 'running')), 'awaiting_rating', (SELECT count(*)
            FROM matches
            WHERE status = 'finished'), 'median_played_ms', (SELECT percentile_cont(0.5) WITHIN GROUP
                (ORDER BY played_ms)
            FROM matches
            WHERE played_at > now() - interval '1 hour'
            AND played_ms IS NOT NULL), 'last_played_at', (SELECT max(played_at)
            FROM matches), 'last_rated_at', (SELECT max(rated_at)
            FROM matches), 'admission_queue', (SELECT count(*)
            FROM model_versions
            WHERE status = 'testing'), 'awaiting_trial', (SELECT count(*)
            FROM model_versions
            WHERE status = 'verified'))) AS body
