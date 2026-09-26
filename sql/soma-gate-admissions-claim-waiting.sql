-- IS ANY ADMISSION WAITING AT ALL, leased or not: the read the idle marker needs. A lapsed lease
-- makes a row claimable again with no write, so the marker may be written only when no row waits,
-- never when rows exist but are leased -- which is why a zero-row claim alone is not enough here.
SELECT EXISTS (SELECT 1 FROM admissions a WHERE a.report IS NULL) AS waiting
