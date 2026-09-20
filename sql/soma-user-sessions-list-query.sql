SELECT me.sid AS session_ok, coalesce((SELECT json_agg(json_build_object('sid', ls.sid, 'issued_at',
                    ls.issued_at, 'expires_at', ls.expires_at, 'last_seen_at', ls.last_seen_at, 'user_agent',
                    ls.user_agent, 'current', ls.sid = me.sid)
            ORDER BY ls.last_seen_at DESC)
        FROM live_sessions ls
        WHERE ls.user_id = ($1)::uuid), '[]'::json) AS body
FROM live_sessions me
WHERE me.sid = ($2)::uuid
AND me.user_id = ($1)::uuid
