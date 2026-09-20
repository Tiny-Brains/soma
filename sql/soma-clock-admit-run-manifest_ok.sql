SELECT ('sha256:' || encode(sha256(convert_to(($2)::text, 'UTF8')), 'hex') = ($1)::text) AS ok,
       length(($2)::text) AS bytes
