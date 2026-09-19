#!/usr/bin/env python3
"""Generate Soma's four cron clocks, the probe channel, their workflows, and the autoscaler query.

    python3 scripts/gen-clocks.py            # rewrite channels/tb-*.json, workflows/tb-*.json
                                             # and scripts/autoscaler.sql
    python3 scripts/gen-clocks.py --check    # fail if the committed files have drifted

Each workflow is a long JSON document whose interesting content is SQL, and SQL written as
single-line JSON string literals is unreviewable -- so the statements live here in readable form
and this script inlines them. The generated files ARE the package: they are committed beside the
authored routes, loaded by scripts/load-package.sh, and what a reviewer reads for the task graph.
Change a statement here, regenerate, and commit both; `--check` (which scripts/check-defs.sh and
scripts/check-sql.sh run) is what catches a generated file that was edited by hand instead.

THE OUTPUT IS FORMATTED BY `orion-server fmt`, because it is committed beside files that are and
check-defs.sh holds the whole repository to the house style. So the generator needs the same
1.8.x binary check-defs.sh does, and `--check` compares formatted text with formatted text.

The clocks read and write through `soma-db`, the owner connector the routes use. No grant stops a
clock reading `sessions` or rewriting an entry: that boundary is review, and `soma-db`'s
`operations.delete = false` is what stops one deleting a row.
"""

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
PKG = HERE.parent


def sql(text: str) -> str:
    """Collapse a readable statement to the single line a JSON field holds.

    Line comments are stripped first: collapsing whitespace would otherwise let a surviving `--`
    comment out the rest of the statement, silently, because the truncated text is often still
    valid SQL. A `--` inside a string literal is left alone.
    """
    out = []
    for line in text.split("\n"):
        i = line.find("--")
        while i != -1:
            if line[:i].count("'") % 2 == 0:      # not inside a string literal
                line = line[:i]
                break
            i = line.find("--", i + 2)
        out.append(line)
    return re.sub(r"\s+", " ", " ".join(out)).strip()


def var(path: str) -> dict:
    return {"var": path}


def first_sweep(task: dict) -> dict:
    """Run this task only on sweep 0 -- the loop replays the whole task list every sweep."""
    task["condition"] = {"==": [var("temp_data.i"), 0]}
    return task


def db_read(connector, query, params, output):
    return {"name": "db_read", "input": {
        "connector": connector, "query": sql(query), "params": params, "output": output}}


def db_write(connector, query, params, output=None):
    inp = {"connector": connector, "query": sql(query), "params": params}
    if output:
        inp["output"] = output
    return {"name": "db_write", "input": inp}


def halt_unless(condition):
    return {"name": "filter", "input": {"condition": condition, "on_reject": "halt"}}


def http(connector, method, path, output, body=None, **extra):
    inp = {"connector": connector, "method": method, "path": path, "output": output}
    if body is not None:
        inp["body"] = body
    inp.update(extra)
    return {"name": "http_call", "input": inp}


def wrote_something(path):
    """A fenced statement learns its fate from rows_affected; zero means the fence moved."""
    return {">": [var(f"{path}.rows_affected"), 0]}


# The occurrence that count's fenced statements prove they still own.
RUN_FENCE = [var("metadata.trigger.scheduled_for"), var("metadata.trigger.attempt")]

IS_FOLD = {"==": [var("temp_data.it.kind"), "fold"]}
IS_PASS = {"==": [var("temp_data.it.decision"), "pass"]}
IS_REJECT = {"==": [var("temp_data.it.decision"), "reject"]}

# Admission: the artifact is in the bucket and nothing has gone wrong with it yet.
#
# `temp_data.head` IS THE RESIDENCY SIGNAL, and it is the same one `ARTIFACT_MISSING` is decided
# on -- one fact, asked once. It used to be `temp_data.resident`, set from the loader's reply
# (`load.models.0.state`), and the rebuild that deleted the loader deleted every task that wrote
# it and left this read behind. Nothing errored: `verify` is the only task gated on this, its
# condition was simply never true, and every submission walked the whole admission, passed every
# gate, and sat in `testing` until it ran out of attempts and was rejected TIMED_OUT.
#
# `.exists`, NEVER THE OBJECT. `storage_head` answers a missing object with `{"exists": false}`
# rather than failing, and an object is truthy -- so read bare, an upload that never happened
# passed as present, `register` 400'd on Orion's own HEAD, and the walk called it
# ADMISSION_UNREACHABLE: ours, refunded, and walked again every tick for ever.
STILL_GOOD = [var("temp_data.head.exists"), {"!": var("temp_data.reason")},
              {"!": var("temp_data.retry")}]

# A registration was built and nothing has been decided yet: the node may be touched.
REGISTERABLE = [{"!!": var("temp_data.reg")}, {"!": var("temp_data.reason")},
                {"!": var("temp_data.retry")}]

# What the walk registers, by reference and digest -- sent by `register` and, after a dead walk's
# leftovers are cleared, by `reregister`.
REGISTRATION = {"manifest": var("temp_data.reg"),
                "artifact": {"connector": "soma-models-internal",
                             "key": var("temp_data.it.artifact_key"),
                             "digest": var("temp_data.it.weights_hash")},
                "tags": ["admission"]}


# ======================================================================= statements

# --- count claims its run fence, monotonically, at its first task.
C_FENCE = """
UPDATE clocks
   SET scheduled_for = ($1)::timestamptz, attempt = ($2)::int, updated_at = now()
 WHERE key = 'count'
   AND (scheduled_for, attempt) < (($1)::timestamptz, ($2)::int)
"""

# --- everything this run will do, as one document -- the matches to fold in finish
# order, then the trials to decide. Folds first, so a trial is decided after every result that
# arrived before it.
C_BATCH_DOC = """
WITH folds AS (
    SELECT json_build_object('kind', 'fold', 'id', m.id) AS item, 0 AS grp, m.played_at AS ord, m.id
      FROM matches m
     WHERE m.status = 'finished' AND m.trial_version_id IS NULL
     ORDER BY m.played_at, m.id
     LIMIT ($1)::int
), verdicts AS (
    SELECT json_build_object(
             'kind', 'verdict', 'model_id', c.id, 'trial_id', t.id,
             -- THE VERSION THIS ONE WOULD REPLACE: the entry's own active version, in the
             -- candidate's own season. Both terms are load-bearing. Entry-scoped, because an owner
             -- now holds one active version PER ENTRY; season-scoped, because they also hold one in
             -- every season they ever finished -- a closed season's active version IS its standing.
             -- Scoped by owner alone, as this read was before the entry split, the scalar subquery
             -- raises "more than one row" the first time a second season opens, and the count clock
             -- dies with the whole ladder behind it.
             'predecessor_id', (SELECT p.id FROM model_versions p
                                 WHERE p.model_id = c.model_id AND p.season_id = c.season_id
                                   AND p.status = 'active'),
             'trials', n.trials,
             -- The strike ceiling is READ OFF THE TRIAL ROW, not off this package's config. It is
             -- the number the wave actually played by, so count now judges a trial by the rule that
             -- was applied to it by construction, rather than because two [vars] in two repositories
             -- were asserted equal.
             -- A REFUSED TRIAL (MODEL_UNAVAILABLE: no runner could serve a seat's model within the
             -- gate's grace) was never played, so it is not the candidate's attempt: `trials`
             -- leaves it out and `refused` counts it against a ceiling of its own, whose reason
             -- names the fleet rather than the model.
             'decision', CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN 'pass'
                              WHEN t.status = 'finished'                           THEN 'reject'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'reject'
                              WHEN n.trials >= tm.trials_max                        THEN 'reject'
                              WHEN n.refused >= tm.trials_max                       THEN 'reject'
                              ELSE 'repair' END,
             'reason',   CASE WHEN t.status = 'finished' AND cs.strikes < t.strike_ceiling THEN NULL
                              WHEN t.status = 'finished'                           THEN 'FORFEIT'
                              WHEN t.status = 'failed' AND t.fault_seat = cs.seat   THEN 'FAULT:' || t.fault_reason
                              WHEN n.trials >= tm.trials_max                        THEN 'UNPLAYABLE'
                              WHEN n.refused >= tm.trials_max                       THEN 'RUNNER_UNAVAILABLE'
                              ELSE NULL END) AS item,
           1 AS grp, t.played_at AS ord, c.id
      FROM model_versions c
      JOIN seasons cse ON cse.id = c.season_id
      CROSS JOIN LATERAL (SELECT coalesce((cse.rules -> 'pairing' ->> 'trials_max')::int,
                                          ($2)::int) AS trials_max) tm
      JOIN LATERAL (SELECT t.* FROM matches t
                     WHERE t.trial_version_id = c.id
                       AND t.status IN ('finished', 'failed', 'cancelled')
                     ORDER BY t.created_at DESC LIMIT 1) t ON true
      JOIN match_seats cs ON cs.match_id = t.id AND cs.version_id = c.id
      JOIN LATERAL (SELECT count(*) FILTER (WHERE x.fault_reason IS DISTINCT FROM 'MODEL_UNAVAILABLE') AS trials,
                           count(*) FILTER (WHERE x.fault_reason = 'MODEL_UNAVAILABLE') AS refused
                      FROM matches x WHERE x.trial_version_id = c.id) n ON true
     WHERE c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running'))
)
SELECT json_build_object('n', count(*),
         'items', coalesce(json_agg(item ORDER BY grp, ord, id), '[]'::json)) AS body
  FROM (SELECT * FROM folds UNION ALL SELECT * FROM verdicts) x
"""

# --- the seats' priors on the ladders this match feeds, as the plugin's input.
C_PRIORS = """
SELECT json_build_object(
         -- The keys `trial_model_id` and `model_id` are the plugin's WIRE FORMAT and stay as they
         -- are though the columns behind them are now named for versions. Renaming a column is a
         -- schema change; renaming these would be a change to tb.rating.trueskill and its tests.
         'id', m.id, 'trial_model_id', m.trial_version_id, 'ladders', m.ladders,
         'seat_count', m.seat_count,
         'seats', (SELECT json_agg(json_build_object(
                      'seat', s.seat, 'model_id', s.version_id, 'rank', s.rank, 'strikes', s.strikes,
                      'ratings', (SELECT json_agg(json_build_object(
                                            'ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                                          ORDER BY r.ladder)
                                    FROM ratings r
                                   WHERE r.version_id = s.version_id AND r.ladder = ANY (m.ladders)))
                    ORDER BY s.seat)
                     FROM match_seats s WHERE s.match_id = m.id)
       ) AS row,
       -- TrueSkill's parameters, read from THE SEASON THIS MATCH BELONGS TO rather than from
       -- [vars]. Bound to the match being folded and not to the run, which is what makes a batch
       -- spanning a season boundary impossible to fold with mixed constants -- there is no
       -- run-scoped copy for the second season's matches to inherit.
       coalesce((se.rules -> 'rating' ->> 'beta')::float8,             ($2)::float8) AS beta,
       coalesce((se.rules -> 'rating' ->> 'tau')::float8,              ($3)::float8) AS tau,
       coalesce((se.rules -> 'rating' ->> 'draw_probability')::float8, ($4)::float8) AS draw_probability
  FROM matches m
  JOIN seasons se ON se.id = m.season_id
 WHERE m.id = ($1)::uuid AND m.status = 'finished'
"""

# --- mark the match rated and apply the posteriors, in one statement under the
# fence. The mark and the writes being one statement is what stops a match being counted twice:
# the second attempt finds status <> 'finished' and updates nothing.
C_FOLD = """
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
       AND m.trial_version_id IS NULL
       AND jsonb_array_length(($4)::jsonb) = m.seat_count * cardinality(m.ladders)
 RETURNING m.id
), post AS (
    SELECT p.*
      FROM mark,
           jsonb_to_recordset(($4)::jsonb)
             -- `model_id` is the plugin's own output key and is a VERSION id; the column below
             -- is named for the wire and joined to ratings.version_id.
             AS p (seat smallint, model_id uuid, ladder text, mu float8, sigma float8)
), applied AS (
    UPDATE ratings r
       SET mu = post.mu, sigma = post.sigma,
           matches_played = r.matches_played + 1, updated_at = now()
      FROM post, ratings old
     WHERE r.version_id = post.model_id AND r.ladder = post.ladder::ladder
       AND old.version_id = r.version_id AND old.ladder = r.ladder
 RETURNING r.version_id, r.ladder, r.matches_played AS seq, post.seat,
           old.mu AS mu_before, old.sigma AS sigma_before, r.mu AS mu_after, r.sigma AS sigma_after
)
INSERT INTO rating_events (version_id, ladder, seq, match_id, seat,
                           mu_before, sigma_before, mu_after, sigma_after)
SELECT a.version_id, a.ladder, a.seq, mark.id, a.seat,
       a.mu_before, a.sigma_before, a.mu_after, a.sigma_after
  FROM applied a, mark
"""

# --- promotion. Mark the trial rated, bump the roster epoch, supersede the
# predecessor, activate the candidate, and seed both its rating rows from the predecessor's with
# sigma inflated -- all in one statement, so a reader never sees half a promotion.
C_PASS = """
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), live AS (
    -- The candidate's season must be live, and the guard sits on the mark because a
    -- data-modifying CTE runs whether or not the outer statement uses it. Never reached in
    -- practice -- a close rejects a waiting candidate in the same statement -- but never is a
    -- promise, and this is a predicate.
    SELECT s.id,
           coalesce((s.rules -> 'rating' ->> 'prior_mu')::float8,        ($5)::float8) AS prior_mu,
           coalesce((s.rules -> 'rating' ->> 'prior_sigma')::float8,     ($6)::float8) AS prior_sigma,
           coalesce((s.rules -> 'rating' ->> 'sigma_inflation')::float8, ($7)::float8) AS inflation
      FROM seasons s JOIN model_versions c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_version_id = ($4)::uuid
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM mark
     WHERE c.key = 'roster'
 RETURNING c.epoch
), pred AS (
    -- The version this one replaces: THE SAME ENTRY'S, in the same season. Scoped by owner, as it
    -- was before the entry split, promoting one of a competitor's models would supersede all of
    -- the others -- their whole portfolio killed by one successful trial.
    UPDATE model_versions p SET status = 'superseded'
      FROM bump, model_versions cand
     WHERE cand.id = ($4)::uuid
       AND p.model_id = cand.model_id
       AND p.season_id = cand.season_id AND p.status = 'active'        -- within the season
 RETURNING p.id
), cand AS (
    UPDATE model_versions c SET status = 'active'
      FROM bump
     WHERE c.id = ($4)::uuid AND c.status = 'verified'
       AND (SELECT count(*) FROM pred) >= 0
 RETURNING c.id, c.weight_class
), seeded AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma, seed_mu, seed_sigma)
    SELECT cand.id, l.ladder,
           coalesce(prev.mu, live.prior_mu),
           coalesce(seed.sigma, live.prior_sigma),
           prev.mu,
           seed.sigma
      FROM cand
      CROSS JOIN live
      CROSS JOIN LATERAL (VALUES (cand.weight_class), ('open'::ladder)) AS l (ladder)
      LEFT JOIN pred ON true
      LEFT JOIN ratings prev ON prev.version_id = pred.id AND prev.ladder = l.ladder
      CROSS JOIN LATERAL (
          SELECT CASE WHEN prev.sigma IS NULL THEN NULL
                      ELSE least(prev.sigma * live.inflation, live.prior_sigma) END AS sigma
      ) seed
 RETURNING version_id, ladder, mu, sigma
)
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT version_id, ladder, 0, mu, sigma FROM seeded
"""

# --- the promoted version's predecessor keeps no queue. Idempotent, and the
# backstop sweep would catch these anyway -- this is what stops the successor waiting for it.
C_WITHDRAW_PRED = """
UPDATE matches m
   SET status = 'cancelled', withdrawn_reason = 'SUPERSEDED',
       successor_version_id = ($2)::uuid, closed_at = now()
 WHERE m.status = 'pending'
   AND EXISTS (SELECT 1 FROM match_seats s WHERE s.match_id = m.id AND s.version_id = ($1)::uuid)
"""

# --- rejection. Also a roster write, so it bumps the epoch: a queued row naming
# this candidate must not be paired against a roster that no longer contains it.
C_REJECT = """
WITH fence AS (
    SELECT key FROM clocks
     WHERE key = 'count' AND scheduled_for = ($1)::timestamptz AND attempt = ($2)::int
       FOR SHARE
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence
     WHERE m.id = ($3)::uuid AND m.status = 'finished'
 RETURNING m.id
), bump AS (
    UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
      FROM fence
     WHERE c.key = 'roster' AND (SELECT count(*) FROM mark) >= 0
 RETURNING c.epoch
)
UPDATE model_versions v
   SET status = 'rejected', reject_reason = ($5)::text
  FROM bump
 WHERE v.id = ($4)::uuid AND v.status = 'verified'
"""

# --- the backstop. Cancel every queued match
# whose season has closed, whose engine has been retired, or whose seats stopped contesting.
# "Contesting" is stated by inclusion -- active, or verified for the candidate seat of its own
# trial -- so a status added later fails closed and is withdrawn. The digest is the ROW'S SEASON'S
# copy, not the game's: a release waiting for the next season must not retire the live one's
# queue. SEASON_CLOSED here is the crash case; the close cancels its own queue.
W_SWEEP = """
UPDATE matches m
   SET status = 'cancelled', closed_at = now(),
       withdrawn_reason =
           CASE WHEN s.closed_at IS NOT NULL            THEN 'SEASON_CLOSED'
                WHEN m.engine_digest <> s.engine_digest THEN 'ENGINE_RETIRED'
                ELSE (SELECT CASE v.status WHEN 'superseded' THEN 'SUPERSEDED'
                                           WHEN 'rejected'   THEN 'REJECTED'
                                           -- the disable cancels its own queue in the same
                                           -- statement; this is the backstop for a race with it
                                           WHEN 'disabled'   THEN 'BASELINE_DISABLED'
                                           ELSE 'SEAT_LEFT' END
                        FROM match_seats st
                        JOIN model_versions v ON v.id = st.version_id
                       WHERE st.match_id = m.id
                         AND NOT (v.status = 'active'
                               OR (v.status = 'verified' AND v.id = m.trial_version_id))
                       ORDER BY st.seat LIMIT 1)
           END,
       -- The successor is THE SAME ENTRY'S next version. Scoped by owner, as it was before the
       -- entry split, this named an arbitrary sibling entry's version -- telling a competitor
       -- their match was cancelled for "v7" when the version that replaced this seat was v3.
       successor_version_id =
           (SELECT succ.id
              FROM match_seats st
              JOIN model_versions gone ON gone.id = st.version_id AND gone.status = 'superseded'
              JOIN model_versions succ ON succ.model_id = gone.model_id
                              AND succ.season_id = gone.season_id AND succ.status = 'active'
             WHERE st.match_id = m.id
             ORDER BY st.seat LIMIT 1)
  FROM seasons s
 WHERE s.id = m.season_id AND m.status = 'pending'
   AND (s.closed_at IS NOT NULL
     OR m.engine_digest <> s.engine_digest
     OR EXISTS (SELECT 1 FROM match_seats st
                  JOIN model_versions v ON v.id = st.version_id
                 WHERE st.match_id = m.id
                   AND NOT (v.status = 'active'
                         OR (v.status = 'verified' AND v.id = m.trial_version_id))))
"""

# --- the close. A live season closes when an admin asked
# (close_requested_at), or when its window has closed and everything has settled: no submission
# undecided, nothing in flight or uncounted, and every active version -- baselines included, since
# they are paced like any other -- at or below settled_sigma with at least burst
# matches ON THE LADDERS IT CAN REACH.
#
# "Can reach" matters: a version alone in its class can never move its class ladder, so judged on
# both ladders it stays `placement` for ever. Judged on open alone until a second version of its
# class arrives, it settles like any other.
#
# rows_affected is zero almost every minute, which is normal and not a halt -- withdraw has no
# fence to lose. Two overlapping runs cannot both close a season: the second's UPDATE ... WHERE
# closed_at IS NULL waits on the row lock, re-evaluates, and finds it taken.
S_CLOSE = """
WITH live AS (
    SELECT s.id
      FROM seasons s
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL
       -- closure.policy 'admin' waits for the request and never settles itself; 'settle' and
       -- 'deadline' both reach the settled test, and 'deadline' additionally gives up waiting
       -- once settle_grace_days have passed since the window closed.
       AND (s.close_requested_at IS NOT NULL
         OR (s.submissions_close_at <= now()
             AND coalesce(s.rules -> 'closure' ->> 'policy', 'settle') <> 'admin'
             AND (
                (coalesce(s.rules -> 'closure' ->> 'policy', 'settle') = 'deadline'
                 AND s.submissions_close_at
                     + make_interval(days => coalesce((s.rules -> 'closure' ->> 'settle_grace_days')::int, 0))
                     <= now())
             OR (
             NOT EXISTS (SELECT 1 FROM model_versions v
                              WHERE v.season_id = s.id AND v.status IN ('testing', 'verified'))
             AND NOT EXISTS (SELECT 1 FROM matches m
                              WHERE m.season_id = s.id
                                AND m.status NOT IN ('rated', 'cancelled', 'failed'))
             AND NOT EXISTS (SELECT 1
                               FROM model_versions v
                               LEFT JOIN ratings r ON r.version_id = v.id
                               LEFT JOIN LATERAL (
                                   SELECT count(*) AS n FROM model_versions o
                                    WHERE o.season_id = v.season_id AND o.status = 'active'
                                      AND o.weight_class = v.weight_class AND o.id <> v.id
                               ) reach ON true
                              WHERE v.season_id = s.id AND v.status = 'active'
                              GROUP BY v.id
                             HAVING count(r.version_id) = 0
                                 OR max(r.sigma) FILTER (WHERE r.ladder = 'open' OR reach.n > 0)
                                    > coalesce((s.rules -> 'rating' ->> 'settled_sigma')::float8,
                                               ($2)::float8)
                                 OR min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0)
                                    < coalesce((s.rules -> 'pairing' ->> 'burst')::int,
                                               ($3)::int))))))
), closed AS (
    UPDATE seasons s SET closed_at = now()
      FROM live WHERE s.id = live.id
 RETURNING s.id
), rejected AS (
    UPDATE model_versions md SET status = 'rejected', reject_reason = 'SEASON_CLOSED'
      FROM closed
     WHERE md.season_id = closed.id AND md.status IN ('testing', 'verified')
 RETURNING md.id
), withdrawn AS (
    UPDATE matches m
       SET status = 'cancelled', withdrawn_reason = 'SEASON_CLOSED', closed_at = now()
      FROM closed
     WHERE m.season_id = closed.id AND m.status = 'pending'
 RETURNING m.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM closed WHERE c.key = 'roster'
"""

# ======================================================================= notifications
#
# WHAT A COMPETITOR IS TOLD, written by the clock that decided it and in the statement right after
# the decision. Four rules every one of these follows, and they are why none of them is inside the
# fenced statement it reports:
#
#   * IT READS THE DECISION OFF THE ROW, never off temp_data. `temp_data` survives a sweep, so a
#     slot read here could be the previous item's; the row cannot. A notify statement run when
#     nothing was decided inserts nothing, which is what makes it safe to run unconditionally.
#   * IT IS KEYED. `ON CONFLICT (user_id, dedupe_key) DO NOTHING` on a key naming the event, so a
#     replayed sweep, a retried occurrence and a second clock deciding the same row insert once.
#   * IT ASKS notification_wanted() INSIDE THE INSERT, so a category that is off writes no row.
#   * ITS TASK IS continue_on_error. A notification is not worth a fold, a verdict or a close: a
#     statement here that fails must cost the notification and nothing else. Folded into C_FOLD
#     as a CTE it would have been exactly-once -- and a CHECK violation in it would have halted
#     the ladder on every occurrence, for ever. The price of the separation is a crash window: a
#     run that dies between the decision and its notify loses that one notification. It can
#     never duplicate one, and never invent one.


def ordinal(expr: str) -> str:
    """`expr` as English: 1st, 2nd, 3rd, 11th, 22nd. One spelling for every writer that prints a
    place, because a feed that says "2nd" in one row and "2th" in the next is two writers."""
    return (f"({expr})::text || CASE WHEN ({expr}) % 100 IN (11, 12, 13) THEN 'th' "
            f"WHEN ({expr}) % 10 = 1 THEN 'st' WHEN ({expr}) % 10 = 2 THEN 'nd' "
            f"WHEN ({expr}) % 10 = 3 THEN 'rd' ELSE 'th' END")


def n_versions(where: str) -> str:
    """A version's decided state, told to its owner. One shape for every place a version is decided:
    admission's verdict, the expiry, the trial's pass and its rejection. The key names the STATUS,
    so `verified` and then `active` are two notifications and a second `active` is none."""
    return f"""
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, data, dedupe_key)
SELECT e.owner_id, 'submissions',
       CASE v.status WHEN 'rejected' THEN 'alert' ELSE 'progress' END,
       CASE v.status WHEN 'verified' THEN 'info' WHEN 'active' THEN 'ok' ELSE 'bad' END,
       e.name || ' v' || v.version ||
         CASE WHEN v.status = 'verified'             THEN ' was admitted'
              WHEN v.status = 'active'               THEN ' passed its trial'
              WHEN v.reject_reason = 'SEASON_CLOSED' THEN ' was withdrawn when its season closed'
              WHEN v.weight_class IS NULL            THEN ' was rejected'
              ELSE                                        ' failed its trial' END,
       -- The rejection's description IS its reason word, as the book spells it; the page
       -- that explains the words is the book's, and a second explanation here would drift from it.
       CASE WHEN v.status = 'verified'
            THEN 'Admitted as ' || v.weight_class || ' at '
                 || to_char(v.size_bytes, 'FM999,999,999,990') || ' bytes. Its trial match is next.'
            WHEN v.status = 'active'
            THEN 'It is on the ' || v.weight_class || ' and open ladders.'
            ELSE v.reject_reason END,
       '/models/' || e.id || '/v' || v.version,
       g.slug, se.slug, e.id, v.id,
       jsonb_strip_nulls(jsonb_build_object(
           'model', e.name, 'version', v.version, 'status', v.status,
           'stage', CASE WHEN v.status = 'verified'             THEN 'admission'
                         WHEN v.status = 'active'               THEN 'trial'
                         WHEN v.reject_reason = 'SEASON_CLOSED' THEN 'season'
                         WHEN v.weight_class IS NULL            THEN 'admission'
                         ELSE                                        'trial' END,
           'class', v.weight_class, 'size_bytes', v.size_bytes, 'params', v.param_count,
           'infer_us', v.infer_us, 'reason_code', v.reject_reason)),
       'version:' || v.id || ':' || v.status
  FROM model_versions v
  JOIN models e   ON e.id = v.model_id
  JOIN games g    ON g.id = v.game_id
  JOIN seasons se ON se.id = v.season_id
 WHERE {where}
   AND v.status IN ('verified', 'active', 'rejected')
   AND notification_wanted(e.owner_id, 'submissions')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
"""


# --- one version, by id: admission's verdict on the item in hand, and count's on a trial.
N_VERSION = n_versions("v.id = ($1)::uuid")

# --- what THIS RUN expired. A_EXPIRE stamps the run's token on the rows it rejects, which is the
# only thing that tells them from every TIMED_OUT row before them; without it this statement would
# re-offer the whole history to the conflict check on every expiry.
N_EXPIRED = n_versions("v.admit_token = ($1)::uuid AND v.reject_reason = 'TIMED_OUT'")

# --- a rated match, told to each seat's owner as their `matches` level allows: `all` hears every
# one, `notable` a first place, any strike or a disqualification. Keyed per SEAT, because a season
# that allows self-pairing seats one owner twice and each seat is its own result. `actor` is the
# best-placed OTHER seat's owner -- the winner when you lost, the runner-up when you won.
N_RESULTS = f"""
WITH m AS (
    SELECT mt.id, mt.seat_count, sm.map_id, g.slug AS game, se.slug AS season
      FROM matches mt
      JOIN games g        ON g.id = mt.game_id
      JOIN seasons se     ON se.id = mt.season_id
      JOIN season_maps sm ON sm.id = mt.season_map_id
     WHERE mt.id = ($1)::uuid AND mt.status = 'rated' AND mt.trial_version_id IS NULL
), seats AS MATERIALIZED (
    SELECT r.* FROM m CROSS JOIN LATERAL match_seat_rows(m.id) r
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, match_id, actor, data, dedupe_key)
SELECT s.owner_id, 'matches', 'result',
       CASE WHEN s.outcome = 'dq'  THEN 'bad'
            WHEN s.strikes > 0     THEN 'warn'
            WHEN s.outcome = 'win' THEN 'ok'
            ELSE                        'info' END,
       s.model_name || ' v' || s.version ||
         CASE WHEN s.outcome = 'dq'                         THEN ' was disqualified'
              WHEN m.seat_count = 2 AND s.outcome = 'win'   THEN ' won'
              WHEN m.seat_count = 2 AND s.outcome = 'draw'  THEN ' drew'
              WHEN m.seat_count = 2                         THEN ' lost'
              ELSE ' placed ' || {ordinal('s.rank')} || ' of ' || m.seat_count END,
       'Scored ' || s.score || ' on ' || m.map_id ||
         CASE WHEN s.strikes = 1 THEN ', with 1 strike'
              WHEN s.strikes > 1 THEN ', with ' || s.strikes || ' strikes'
              ELSE '' END || '.',
       '/matches/' || m.id,
       m.game, m.season, s.model_id, s.version_id, m.id,
       (SELECT o.owner FROM seats o WHERE o.seat <> s.seat ORDER BY o.rank NULLS LAST, o.seat LIMIT 1),
       jsonb_strip_nulls(jsonb_build_object(
           'place', s.rank, 'of', m.seat_count, 'score', s.score, 'strikes', s.strikes,
           'outcome', s.outcome, 'class', s.class, 'map', m.map_id,
           -- the change in the CONSERVATIVE rating on open, which is the number a ladder prints
           'delta', (SELECT round(((ev.mu_after - 3 * ev.sigma_after)
                                   - (ev.mu_before - 3 * ev.sigma_before))::numeric, 2)
                       FROM rating_events ev
                      WHERE ev.match_id = m.id AND ev.seat = s.seat AND ev.ladder = 'open'),
           'rating', (SELECT round((ev.mu_after - 3 * ev.sigma_after)::numeric, 2)
                        FROM rating_events ev
                       WHERE ev.match_id = m.id AND ev.seat = s.seat AND ev.ladder = 'open'))),
       'result:' || m.id || ':' || s.seat
  FROM m CROSS JOIN seats s
 WHERE s.owner_id IS NOT NULL AND s.rank IS NOT NULL
   AND notification_wanted(s.owner_id, 'matches', s.rank = 1 OR s.strikes > 0)
ON CONFLICT (user_id, dedupe_key) DO NOTHING
"""

# --- a rank that moved, on a ladder this fold changed, told to the owner of each seat whose rank it
# was. THE RANK IS model_ratings()'s -- conservative DESC, then version id -- over the same
# ladder_field(), computed twice: before, with this match's seats at their `mu_before`/`sigma_before`
# from its rating events, and after. Everyone else on the ladder is at their current rating in both,
# which is exactly what this fold did not change.
#
# ONLY A SETTLED RATING is told. A version in placement moves on nearly every match, and a feed that
# says so eight times in its first hour is the noise that makes a competitor turn a category off;
# `settled_sigma` is the season's, as the leaderboard's `provisional` is. The fold only tells the
# SEATS: a version displaced by two others' match is not told, because nothing it did moved it.
N_RANKS = f"""
WITH m AS (
    SELECT mt.id, mt.season_id, se.slug AS season, se.rules, g.slug AS game
      FROM matches mt
      JOIN seasons se ON se.id = mt.season_id
      JOIN games g    ON g.id = mt.game_id
     WHERE mt.id = ($1)::uuid AND mt.status = 'rated' AND mt.trial_version_id IS NULL
), ev AS (
    SELECT e.version_id, e.ladder, e.sigma_after,
           e.mu_before - 3 * e.sigma_before AS before,
           e.mu_after  - 3 * e.sigma_after  AS after
      FROM rating_events e JOIN m ON e.match_id = m.id
), field AS MATERIALIZED (
    SELECT l.ladder, f.version_id, coalesce(ev.before, f.conservative) AS before, f.conservative AS after
      FROM m
     CROSS JOIN (SELECT DISTINCT ladder FROM ev) l
     CROSS JOIN LATERAL ladder_field(m.season_id, l.ladder) f
      LEFT JOIN ev ON ev.version_id = f.version_id AND ev.ladder = l.ladder
), moved AS (
    SELECT ev.version_id, ev.ladder, ev.sigma_after, ev.after,
           (SELECT count(*) + 1 FROM field x
             WHERE x.ladder = ev.ladder AND x.version_id <> ev.version_id
               AND (x.before > ev.before OR (x.before = ev.before AND x.version_id < ev.version_id))) AS prev_rank,
           (SELECT count(*) + 1 FROM field x
             WHERE x.ladder = ev.ladder AND x.version_id <> ev.version_id
               AND (x.after > ev.after OR (x.after = ev.after AND x.version_id < ev.version_id))) AS rank,
           (SELECT count(*) FROM field x WHERE x.ladder = ev.ladder) AS field
      FROM ev
     WHERE EXISTS (SELECT 1 FROM field x WHERE x.ladder = ev.ladder AND x.version_id = ev.version_id)
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, model_id, version_id, match_id, data, dedupe_key)
SELECT e.owner_id, 'ratings', 'rank',
       CASE WHEN mv.rank < mv.prev_rank THEN 'ok' ELSE 'info' END,
       e.name || ' v' || v.version ||
         CASE WHEN mv.rank < mv.prev_rank THEN ' rose to ' ELSE ' fell to ' END ||
         {ordinal('mv.rank')} || ' on the ' || mv.ladder || ' ladder',
       CASE WHEN mv.rank < mv.prev_rank THEN 'Up from ' ELSE 'Down from ' END ||
         {ordinal('mv.prev_rank')} || ' of ' || mv.field || '.',
       '/leaderboard?season=' || m.season ||
         CASE WHEN mv.ladder = 'open' THEN '' ELSE '&ladder=' || mv.ladder END,
       m.game, m.season, e.id, v.id, m.id,
       jsonb_build_object('ladder', mv.ladder, 'rank', mv.rank, 'prev_rank', mv.prev_rank,
                          'of', mv.field, 'class', v.weight_class,
                          'rating', round(mv.after::numeric, 2)),
       'rank:' || m.id || ':' || v.id || ':' || mv.ladder
  FROM m
 CROSS JOIN moved mv
  JOIN model_versions v ON v.id = mv.version_id
  JOIN models e         ON e.id = v.model_id
 WHERE mv.rank <> mv.prev_rank
   AND mv.sigma_after <= coalesce((m.rules -> 'rating' ->> 'settled_sigma')::float8, ($2)::float8)
   AND notification_wanted(e.owner_id, 'ratings')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
"""

# --- the season this run closed, told to everyone who entered a version in it, with where they
# finished on open. The season is the game's most recently closed one: the task runs only when the
# close wrote something, and the close is the only statement that sets closed_at. The rank is
# model_ratings()'s -- conservative DESC, then id -- over the same ladder_field(), so this sentence
# and the version page cannot disagree about who was fifth.
N_SEASON = f"""
WITH closed AS (
    SELECT s.id, s.slug AS season, s.name AS season_name, g.slug
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NOT NULL
     ORDER BY s.closed_at DESC
     LIMIT 1
), standing AS (
    SELECT f.owner_id, min(f.rank) AS rank, max(f.field) AS field
      FROM (SELECT lf.owner_id,
                   row_number() OVER (ORDER BY lf.conservative DESC, lf.version_id) AS rank,
                   count(*) OVER () AS field
              FROM closed, ladder_field(closed.id, 'open') lf) f
     GROUP BY f.owner_id
), entrants AS (
    SELECT DISTINCT e.owner_id
      FROM closed
      JOIN model_versions v ON v.season_id = closed.id
      JOIN models e         ON e.id = v.model_id
)
INSERT INTO notifications (user_id, category, kind, tone, subject, description, link,
                           game, season, data, dedupe_key)
SELECT en.owner_id, 'season', 'season', 'info',
       closed.season_name || ' has closed',
       CASE WHEN st.rank IS NULL THEN 'The final standings are in.'
            ELSE 'You finished ' || {ordinal('st.rank')} || ' of ' || st.field || ' on the open ladder.' END,
       '/leaderboard?season=' || closed.season,
       closed.slug, closed.season,
       jsonb_strip_nulls(jsonb_build_object('rank', st.rank, 'of', st.field, 'ladder', 'open')),
       'season-closed:' || closed.id
  FROM closed
 CROSS JOIN entrants en
  LEFT JOIN standing st ON st.owner_id = en.owner_id
 WHERE notification_wanted(en.owner_id, 'season')
ON CONFLICT (user_id, dedupe_key) DO NOTHING
"""

# --- the game id from its slug. [vars] carries the slug: the id is generated when the volume is
# seeded and is not knowable at config time.
P_GAME = "SELECT id FROM games WHERE slug = ($1)::text"

# --- the roster epoch, read once at run start. Every insert then checks it.
P_EPOCH = "SELECT epoch FROM clocks WHERE key = 'roster'"

# --- everything pair needs to choose, at one instant -- what each version wants,
# who may be seated opposite, which of the season's boards each has played, and how much room the
# depth target leaves.
P_DEMAND_DOC = """
WITH live AS (
    -- Only the live season's versions want anything or may be seated. No live season,
    -- no demand, nothing paired -- the paused state. The season's rules come with it: every cap
    -- below is coalesce(rule, var), so a season that declares nothing paces exactly as the deploy.
    SELECT id, rules FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), lim AS (
    SELECT coalesce((live.rules -> 'pairing' ->> 'burst')::int,             ($2)::int)    AS burst,
           coalesce((live.rules -> 'pairing' ->> 'steady_cap')::int,        ($3)::int)    AS steady_cap,
           coalesce((live.rules -> 'rating'  ->> 'settled_sigma')::float8,  ($4)::float8) AS settled_sigma,
           coalesce((live.rules -> 'pairing' ->> 'cross_class_fraction')::float8, ($6)::float8)
                                                                                         AS cross_class_fraction,
           coalesce((live.rules -> 'pairing' ->> 'self_pairing')::bool,     false)        AS self_pairing,
           -- NULL means uncapped, and it must stay NULL rather than become a sentinel here:
           -- Postgres least() SKIPS nulls, so `least(want, NULL)` is `want` and an absent cap
           -- would silently disable itself. Every use below coalesces explicitly.
           (live.rules -> 'pairing' ->> 'queue_share_max')::int                          AS queue_share_max
      FROM live
), maps AS (
    -- THE BOARDS IN PLAY, read on every run: the season's ENABLED maps, which an admin may
    -- change while the season is live. The season is the only source -- there is no deploy list to
    -- fall back to -- so a season with none enabled pairs nothing, the same paused state as no
    -- season at all. A match already queued keeps the board it was paired on.
    SELECT sm.id, sm.players
      FROM season_maps sm JOIN live ON live.id = sm.season_id
     WHERE sm.enabled
     ORDER BY sm.added_at, sm.map_id
), v AS (
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class,
           max(r.sigma)          FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma,
           min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played
      FROM model_versions vv
      JOIN models e ON e.id = vv.model_id
      JOIN live     ON live.id = vv.season_id
      LEFT JOIN ratings r ON r.version_id = vv.id
      LEFT JOIN LATERAL (
          -- a class ladder is reachable only if another active version of the class is in the
          -- season; a version alone in its class is judged on open alone, or it never settles
          SELECT count(*) AS n FROM model_versions o
           WHERE o.season_id = vv.season_id AND o.status = 'active'
             AND o.weight_class = vv.weight_class AND o.id <> vv.id
      ) reach ON true
     WHERE vv.status = 'active'
     GROUP BY vv.id, e.owner_id, vv.weight_class
), f AS (
    -- In flight INCLUDES a finished row count has not yet folded: its result is what the next
    -- pairing's prior will move, which is the whole reason the cap exists. Without it, in the ten
    -- seconds between Kalam finishing a burst and count folding it, played is still 0 and in_flight
    -- is 0, and pair would insert a second burst.
    SELECT s.version_id AS model_id, count(*) AS in_flight
      FROM match_seats s
      JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY s.version_id
), w AS (
    -- No branch for a baseline, and none may come back: it is paced like every version.
    -- The one thing a baseline does alone is sit opposite every trial, which is P_TRIALS'.
    SELECT v.model_id, v.owner_id, v.weight_class, v.sigma, v.played,
           coalesce(f.in_flight, 0) AS in_flight,
           CASE WHEN v.played < lim.burst         THEN 'placement'
                WHEN v.sigma  > lim.settled_sigma THEN 'unsettled'
                ELSE                                   'settled' END AS state,
           CASE WHEN v.played < lim.burst         THEN lim.burst
                WHEN v.sigma  > lim.settled_sigma THEN lim.steady_cap
                ELSE                                   0 END AS cap
      FROM v CROSS JOIN lim LEFT JOIN f ON f.model_id = v.model_id
), owner_load AS (
    -- What each owner already holds across ALL of their entries. Trials are EXCLUDED: a candidate
    -- whose owner is at their share would otherwise never get its trial and would eventually be
    -- rejected UNPLAYABLE for a queueing rule.
    SELECT e.owner_id, count(*) AS in_flight
      FROM match_seats st
      JOIN matches m       ON m.id = st.match_id
      JOIN model_versions o ON o.id = st.version_id
      JOIN models e         ON e.id = o.model_id
     WHERE m.game_id = ($1)::uuid AND m.trial_version_id IS NULL
       AND m.status IN ('pending', 'claimed', 'running', 'finished')
     GROUP BY e.owner_id
), wants AS (
    -- pairing.queue_share_max caps ONE OWNER'S share of the queue across every entry they hold.
    -- Allocated with a running sum rather than per row: `least(want, share)` on each row would let
    -- each of a competitor's five models claim the whole budget, which is five times the cap.
    -- The order is deterministic (want DESC, model_id) because the plugin must be replayable from
    -- this document alone.
    SELECT w.model_id, w.owner_id, w.weight_class, w.state, w.sigma, w.played, w.in_flight,
           greatest(least(
               greatest(w.cap - w.in_flight, 0),
               coalesce(lim.queue_share_max, 2147483647)
                 - coalesce(ol.in_flight, 0)
                 - coalesce(sum(greatest(w.cap - w.in_flight, 0)) OVER (
                       PARTITION BY w.owner_id
                       ORDER BY greatest(w.cap - w.in_flight, 0) DESC, w.model_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
           ), 0) AS want
      FROM w CROSS JOIN lim LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id
), pool AS (
    SELECT vv.id AS model_id, e.owner_id, vv.weight_class,
           (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                            ORDER BY r.ladder) FROM ratings r WHERE r.version_id = vv.id) AS ratings
      FROM model_versions vv
      JOIN models e ON e.id = vv.model_id
      JOIN live     ON live.id = vv.season_id
     WHERE vv.status = 'active'
), played AS (
    SELECT s.version_id AS model_id, m.season_map_id AS map, count(*) AS n
      FROM match_seats s JOIN matches m ON m.id = s.match_id
     WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated')
     GROUP BY s.version_id, m.season_map_id
), depth AS (
    SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending'
)
SELECT json_build_object(
         'demand', (SELECT coalesce(sum(want), 0) FROM wants),
         'depth',  (SELECT pending FROM depth),
         'room',   greatest(least((SELECT coalesce(sum(want), 0) FROM wants),
                                  ($5)::int - (SELECT pending FROM depth)), 0),
         'wants',  (SELECT coalesce(json_agg(wants ORDER BY want DESC, sigma DESC), '[]'::json)
                      FROM wants WHERE want > 0),
         'pool',   (SELECT coalesce(json_agg(pool), '[]'::json) FROM pool),
         'played', (SELECT coalesce(json_agg(played), '[]'::json) FROM played),
         -- The season's pairing policy, so the plugin reads it from the document it is already
         -- given rather than from a second input the caller has to keep in step.
         'limits', (SELECT json_build_object(
                        'self_pairing',         lim.self_pairing,
                        'cross_class_fraction', lim.cross_class_fraction,
                        'maps',                 (SELECT coalesce(json_agg(json_build_object(
                                                     'id', mp.id, 'players', mp.players)), '[]'::json)
                                                   FROM maps mp)) FROM lim),
         -- How many more seats each owner may hold. ABSENT MEANS UNCAPPED -- the same convention
         -- `want` uses -- and a season that sets a share names every owner, baselines included.
         'owners', (SELECT coalesce(json_agg(json_build_object(
                        'owner_id', o.owner_id,
                        'in_flight', o.in_flight,
                        'room', greatest(lim.queue_share_max - o.in_flight, 0))), '[]'::json)
                      FROM (SELECT DISTINCT w.owner_id,
                                   coalesce(max(ol.in_flight), 0) AS in_flight
                              FROM w LEFT JOIN owner_load ol ON ol.owner_id = w.owner_id
                             GROUP BY w.owner_id) o, lim
                     WHERE lim.queue_share_max IS NOT NULL)) AS body
"""

# --- how many runners the ladder wants, for an external autoscaler to poll: pair's own demand CTEs,
# taken from P_DEMAND_DOC so the two cannot drift, with the scaling arithmetic in place of pair's
# document. Written readable (comments kept) to scripts/autoscaler.sql, and PREPAREd by check-sql.sh.
AUTOSCALER_SQL = """\
-- GENERATED by scripts/gen-clocks.py from the pair clock's demand statement. Edit it there.
--
-- How many runners the ladder wants now. It reads DEMAND, which leads the queue -- a runner is asked
-- for before the rows it will claim exist -- and never queue depth alone: pair caps the queue at
-- its depth target, so a scaler reading depth would cap the fleet with it. Only rows on the live
-- season's engine count, so a rolling engine change does not ask for runners to drain the old
-- engine's rows. The latency guard adds one runner, never a jump.
--
--   $1 game id           $2 burst           $3 steady_cap       $4 settled_sigma
--   $5 matches one runner plays at once (its lanes)             $6 cross_class_fraction
--   $7 min runners       $8 max runners     $9 seconds the oldest pending row may wait
--                                              before one runner more is asked for
""" + P_DEMAND_DOC.split("\nSELECT json_build_object(")[0].strip("\n") + """, q AS (
    SELECT count(*) FILTER (WHERE m.status = 'pending')                        AS depth,
           count(*) FILTER (WHERE m.status IN ('pending','claimed','running')) AS outstanding,
           coalesce(extract(epoch FROM now() -
                min(m.created_at) FILTER (WHERE m.status = 'pending')), 0)     AS oldest_pending_s
      FROM matches m
      JOIN seasons s ON s.id = m.season_id AND s.closed_at IS NULL
     WHERE m.game_id = ($1)::uuid
       AND m.engine_digest = s.engine_digest
), total AS (
    SELECT coalesce(sum(want), 0) AS want FROM wants
)
SELECT total.want, q.depth, q.outstanding, round(q.oldest_pending_s)::int AS oldest_pending_s,
       least(($8)::int, greatest(($7)::int,
           ceil((total.want + q.outstanding)::numeric / ($5)::int)::int
         + CASE WHEN q.oldest_pending_s > ($9)::int THEN 1 ELSE 0 END
       )) AS replicas
  FROM total, q
"""

# --- the trial pairings, chosen in SQL rather than by the plugin. The choice is
# mechanical -- a waiting candidate, the board after its last trial's, and baselines to fill it --
# and it must not depend on anything the plugin might be carrying.
#
# THE BOARD DECIDES THE SEAT COUNT, so the board is picked first and the baselines drawn to fill
# it -- and it is picked only from the season's ENABLED boards its baselines CAN fill. A trial
# that does not land does not count, so the rotation (`trials % n`) would otherwise stop on an
# eight-seat board against three baselines and offer that same board every run, for ever: the
# candidate waits on a board it can never be seated on. With no board fillable at all -- or none
# enabled -- it waits, which is the honest reading of an empty roster or an empty season.
#
# A LIVE TRIAL INCLUDES A FINISHED ONE, exactly as `matches_one_live_trial_uniq` counts it: played
# but not yet decided by count. Leave `finished` out and a pair run that lands in that window picks
# the candidate again, the insert breaks the unique index, and the run dies with every pairing
# after it in the plan.
#
# A REFUSED TRIAL IS NOT THE CANDIDATE'S ATTEMPT. A row that failed MODEL_UNAVAILABLE was never
# played: no runner could serve some seat's model within the gate's grace. It spends no repair and
# does not rotate the board, and has a budget of its own (`refused`, the same ceiling), which
# count turns into RUNNER_UNAVAILABLE rather than blaming the model with UNPLAYABLE.
P_TRIALS = """
WITH cand AS (
    SELECT c.id, c.game_id, c.season_id, c.model_id, c.weight_class, e.owner_id, s.rules,
           (SELECT count(*) FROM matches x WHERE x.trial_version_id = c.id
               AND x.fault_reason IS DISTINCT FROM 'MODEL_UNAVAILABLE') AS trials,
           (SELECT count(*) FROM matches x WHERE x.trial_version_id = c.id
               AND x.fault_reason = 'MODEL_UNAVAILABLE') AS refused
      FROM model_versions c
      JOIN models e  ON e.id = c.model_id
      JOIN seasons s ON s.id = c.season_id
     WHERE c.game_id = ($1)::uuid AND c.status = 'verified'
       AND NOT EXISTS (SELECT 1 FROM matches l WHERE l.trial_version_id = c.id
                          AND l.status IN ('pending', 'claimed', 'running', 'finished'))
), pick AS (
    SELECT cand.*, p.id AS map, p.players
      FROM cand
      JOIN LATERAL (
          -- The season's enabled boards in the order they were added, narrowed to the ones this
          -- season's baselines can seat: the candidate, and one baseline of a different owner in
          -- every other seat, exactly as `seated` below draws them. The candidate's `trials`
          -- rotates over them, so a re-pair changes the board.
          SELECT b.id, b.players
            FROM (SELECT sm.id, sm.players,
                         row_number() OVER (ORDER BY sm.added_at, sm.map_id) - 1 AS k,
                         count(*) OVER () AS n
                    FROM season_maps sm
                   WHERE sm.season_id = cand.season_id AND sm.enabled
                     AND sm.players <= 1 + (
                         SELECT count(DISTINCT be.owner_id)
                           FROM model_versions bv
                           JOIN models be ON be.id = bv.model_id
                           JOIN users ub  ON ub.id = be.owner_id AND ub.role = 'baseline'
                          WHERE bv.game_id = cand.game_id AND bv.season_id = cand.season_id
                            AND bv.status = 'active')) b
           WHERE b.k = cand.trials % b.n
      ) p ON true
     WHERE cand.trials < coalesce((cand.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int)
       AND cand.refused < coalesce((cand.rules -> 'pairing' ->> 'trials_max')::int, ($2)::int)
), seated AS (
    SELECT pick.id AS trial_version_id, pick.map, pick.players,
           jsonb_build_array(pick.id) || coalesce(opp.ids, '[]'::jsonb) AS seats
      FROM pick
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(b.id ORDER BY b.rn) AS ids
            FROM (SELECT DISTINCT ON (be.owner_id) b.id, be.owner_id,
                         row_number() OVER (
                             ORDER BY (b.weight_class = pick.weight_class) DESC,
                                      (SELECT count(*) FROM match_seats s
                                         JOIN matches m ON m.id = s.match_id
                                        WHERE s.version_id = b.id
                                          AND m.status IN ('pending', 'claimed', 'running')),
                                      b.id) AS rn
                    FROM model_versions b
                    JOIN models be ON be.id = b.model_id
                    JOIN users ub  ON ub.id = be.owner_id AND ub.role = 'baseline'
                   WHERE b.game_id = pick.game_id AND b.season_id = pick.season_id
                     AND b.status = 'active'
                     -- ONE SEAT PER OWNER among the opponents, and this is not cosmetic: a season
                     -- forbidding self-pairing makes P_INSERT refuse a match seating two versions
                     -- of one owner, and a trial is plan item 0. A trial the insert refuses halts
                     -- the whole run, every run, for ever -- so trials must never propose one.
                   ORDER BY be.owner_id, b.id) b
           WHERE b.rn < pick.players
      ) opp ON true
)
SELECT json_build_object('n', count(*), 'pairings', coalesce(json_agg(json_build_object(
         'seats', seats, 'trial', trial_version_id, 'map', map,
         'seed', (random() * 2147483647)::bigint)), '[]'::json)) AS body
  FROM seated
 WHERE jsonb_array_length(seats) = players
"""

# --- one pairing, inserted under the epoch read at run start. The statement derives
# the hashes, the ladders, the seat count and the contesting check itself, so the plugin supplies
# only ids, a board and a seed -- and a pairing decided against a roster that has moved, or on a
# board an admin has since disabled, inserts nothing.
P_INSERT = """
WITH season AS (
    -- The live season supplies the digest and is what every seat must belong to. No live
    -- season, or a seat from another season, and nothing is inserted -- pair halts and re-reads.
    SELECT s.id, s.game_id, s.engine_digest, s.rules
      FROM seasons s
      JOIN games g ON g.id = s.game_id AND g.slug = ($2)::text
     WHERE s.closed_at IS NULL
), board AS (
    -- THE BOARD DECIDES THE SEAT COUNT, and the statement reads it rather than trusting the plan:
    -- an enabled map of THIS season, or nothing is inserted. A board disabled between pair's
    -- read and this insert is how a stale plan would otherwise queue a match on it.
    SELECT sm.id, sm.players
      FROM season_maps sm JOIN season ON season.id = sm.season_id
     WHERE sm.id = ($4)::uuid AND sm.enabled
), seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, v.id AS version_id, e.owner_id,
           v.weights_hash, v.manifest_hash, v.weight_class
      FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (version_id, ord)
      JOIN model_versions v ON v.id = seat.version_id
      JOIN models e         ON e.id = v.model_id
      JOIN season           ON season.id = v.season_id
     WHERE v.status = 'active'
        OR (v.status = 'verified' AND v.id = ($6)::uuid)
), m AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders,
                         trial_version_id, pairing_id, strike_ceiling)
    SELECT season.game_id, season.id, season.engine_digest, ($3)::bigint, board.id, board.players,
           CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[]
                WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1
                     THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[]
                ELSE ARRAY['open']::ladder[]
           END,
           ($6)::uuid, ($7)::uuid,
           -- THE RULE THE WAVE WILL PLAY BY, pinned onto the row here and read from it by Kalam
           -- and by count. NOT NULL on the column is deliberate: if both the season and the deploy
           -- were silent this insert fails, loudly, here -- where a halt is correct -- instead of
           -- Kalam comparing a strike count against null, which is TRUE, and forfeiting every seat
           -- on turn 0.
           coalesce((season.rules -> 'pairing' ->> 'forfeit_strikes')::smallint, ($8)::smallint)
      FROM season
      JOIN board ON true
      JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence
        ON true
     WHERE (SELECT count(*) FROM seated) = cardinality(($5)::uuid[])
       AND cardinality(($5)::uuid[]) = board.players
       -- SELF-PAIRING IS REFUSED HERE AND NOT ONLY IN THE PLUGIN. Two versions of one owner in one
       -- match is a free rating transfer between a competitor's own entries: the ladder is wrong,
       -- not merely worse, so it is correctness and belongs in the statement. The plugin's job is
       -- never to propose what this would refuse; this statement's job is to refuse it anyway.
       -- Trials are exempt: a trial is the candidate plus baselines, and the candidate's own owner
       -- is never among them.
       AND (($6)::uuid IS NOT NULL
         OR coalesce((season.rules -> 'pairing' ->> 'self_pairing')::bool, false)
         OR (SELECT count(DISTINCT owner_id) FROM seated) = cardinality(($5)::uuid[]))
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash, paired_ratings)
SELECT m.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash,
       (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                         ORDER BY r.ladder)
          FROM ratings r WHERE r.version_id = s.version_id)
  FROM m, seated s
"""

# ======================================================================= the channels
# Every channel is the same cron shape: one workflow, its own `forbid` singleton keyed on the
# clock's name, and the `latest` misfire policy so a node that fell behind runs the newest
# occurrence rather than replaying the backlog. Only the cadence and the run timeout differ.
#
# admit's timeout_ms is deliberately far above admit_timeout_s: this bounds a RUN, which is up to
# admit_batch submissions, while the per-submission timeout is what makes a stuck one retryable.
# Confusing the two is how a batch of four small models gets killed because the first was large.
CHANNELS = [
    {
        "channel_id": f"tb-{key}",
        "name": f"tb-{key}",
        "tags": ["pkg:soma"],
        "channel_type": "async",
        "protocol": "cron",
        "workflow_id": f"tb-{key}-run",
        "transport_config": {
            "schedule": schedule,
            "timezone": "UTC",
            "misfire_policy": "latest",
            "concurrency": {"policy": "forbid", "key": key},
        },
        "config": {
            "timeout_ms": timeout_ms,
            "tracing": {"$from": "constants.clock_tracing"},
        },
    }
    for key, schedule, timeout_ms in [
        ("withdraw", "0 * * * * *", 30000),
        ("count", "*/10 * * * * *", 60000),
        ("pair", "*/15 * * * * *", 60000),
        ("admit", "*/20 * * * * *", 600000),
    ]
]

# The probe is NOT a clock. It is a data channel the admit walk calls with `channel_call`, because
# the number of reference observations is the game's and a task list is fixed -- so the loop has to
# be a workflow's, and a workflow is reached through a channel. `sync` so the caller gets the
# answer, and internal-only: nothing outside this package's own admit workflow may reach it.
#
# A `rest` channel always registers its route, so `auth` is what closes it. Orion holds an HTTP
# caller to a channel's `auth` and never a `channel_call`, and `probe_auth` names an audience no
# route ever mints a token for -- so every request from outside is a 401 and the admit walk is
# untouched. No rate limit: one would apply to `channel_call` too, and throttle admission.
CHANNELS.append({
    "channel_id": "tb-probe",
    "name": "tb-probe",
    "tags": ["pkg:soma"],
    "channel_type": "sync",
    "protocol": "rest",
    "methods": ["POST"],
    "route_pattern": "/internal/probe/adapter",
    "workflow_id": "tb-probe-run",
    "config": {
        "response": {"mode": "shaped"},
        "timeout_ms": 120000,
        "auth": {"$from": "constants.probe_auth"},
        "tracing": {"$from": "constants.clock_tracing"},
    },
})

# ====================================================================== the workflows

WITHDRAW = {
    "workflow_id": "tb-withdraw-run",
    "name": "Clock: withdraw",
    "description": (
        "The backstop clock, and the season's. Two idempotent statements a minute, neither fenced. "
        "The sweep cancels every queued match whose season has closed, whose engine has been "
        "retired or whose seats have stopped contesting, recording why and, where there is one, "
        "the successor that replaced the seat. The close ends the game's live season when an admin "
        "has asked or when its window has closed and every score has settled -- no submission "
        "undecided, nothing in flight, every active version at or below settled_sigma with at "
        "least burst matches. rows_affected is zero almost every minute in both, which is not a "
        "halt. Promotion does its own withdraw and the close cancels its own queue, so a "
        "persistently non-zero sweep count is a signal, not routine. "
        "A close that wrote is followed by one "
        "notification per entrant, keyed on the season, in a task that may fail without "
        "failing the close."
    ),
    "tags": ["pkg:soma"],
    "condition": True,
    "tasks": [
        {"id": "sweep", "name": "Cancel what can no longer be played",
         "function": db_write("soma-db", W_SWEEP, [], "temp_data.swept")},
        {"id": "game", "name": "Resolve the game",
         "function": db_read("soma-db", P_GAME, [var("metadata.vars.game")], "temp_data.game")},
        {"id": "close", "name": "Close the season if it has settled or was asked to",
         "function": db_write("soma-db", S_CLOSE, [
             var("temp_data.game.0.id"),
             var("metadata.vars.settled_sigma"),
             var("metadata.vars.burst")], "temp_data.closed")},
        # Only after a close that wrote: withdraw runs every minute and a close is rare, and the
        # statement reads "the most recently closed season", which is only this run's close when
        # this run made one.
        {"id": "notify_closed", "name": "Tell everyone who entered that the season closed",
         "condition": wrote_something("temp_data.closed"),
         "continue_on_error": True,
         "function": db_write("soma-db", N_SEASON, [var("temp_data.game.0.id")],
                              "temp_data.notified_closed")},
    ],
}

COUNT = {
    "workflow_id": "tb-count-run",
    "name": "Clock: count",
    "description": (
        "The only writer of a ladder. Claims its run fence at the first task and halts if it lost, "
        "then walks one document of work: every unmarked finished match in finish order, followed "
        "by every trial that has reached a terminal state. A fold is one plugin call and one fenced "
        "statement; a verdict is promotion (two statements) or rejection or nothing at all. "
        "Folds come first so a trial is decided after every result that arrived before it. "
        "A fold that affects zero rows halts the run -- the fence moved, or the row was already "
        "counted -- and the next occurrence starts from a clean read. A pass that affects zero rows "
        "does not halt: a concurrent run decided the candidate, and the withdraw after it is "
        "idempotent. The loop's `max` is a bound, never the terminator; the `more` filter is. "
        "Each fold, pass and rejection is followed by its notification -- a separate, keyed, "
        "continue_on_error statement that reads the decision off the row, so a notification can be "
        "lost to a crash between the two but never costs a fold or a verdict."
    ),
    "tags": ["pkg:soma"],
    "condition": True,
    "loop": {"counter": "i", "max": 400},
    "tasks": [
        first_sweep({"id": "fence", "name": "Claim the run fence",
                     "function": db_write("soma-db", C_FENCE, RUN_FENCE,
                                          "temp_data.fence")}),
        first_sweep({"id": "fenced", "name": "Halt if a newer run holds it",
                     "function": halt_unless(wrote_something("temp_data.fence"))}),
        first_sweep({"id": "batch", "name": "Read this run's work",
                     "function": db_read("soma-db", C_BATCH_DOC, [
                         var("metadata.vars.count_batch"),
                         var("metadata.vars.repair_cap")], "temp_data.rows")}),
        {"id": "more", "name": "Stop when the work runs out",
         "function": halt_unless({"<": [var("temp_data.i"), var("temp_data.rows.0.body.n")]})},
        {"id": "item", "name": "Take item i",
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.it",
              "logic": {"val": ["temp_data", "rows", 0, "body", "items", {"val": ["temp_data", "i"]}]}}]}}},

        # The [vars] are the statement's FALLBACKS -- it coalesces each against the match's season
        # rule -- so they go in as $2..$4, and the rating reads what the row says. Passing the vars
        # straight to the rating instead would drop a season's rating rule on the floor; passing
        # only $1 fails every fold's validation, and nothing is ever rated.
        {"id": "priors", "name": "Read the seats' priors",
         "condition": IS_FOLD,
         "function": db_read("soma-db", C_PRIORS, [
             var("temp_data.it.id"),
             var("metadata.vars.ts_beta"),
             var("metadata.vars.ts_tau"),
             var("metadata.vars.ts_draw_probability")], "temp_data.match")},
        {"id": "rate", "name": "TrueSkill",
         "condition": IS_FOLD,
         "function": {"name": "tb.rating.trueskill", "input": {
             "match": var("temp_data.match.0.row"),
             "beta": var("temp_data.match.0.beta"),
             "tau": var("temp_data.match.0.tau"),
             "draw_probability": var("temp_data.match.0.draw_probability"),
             "output": "temp_data.post"}}},
        {"id": "fold", "name": "Mark rated and apply the posteriors",
         "condition": IS_FOLD,
         "function": db_write("soma-db", C_FOLD, RUN_FENCE + [
             var("temp_data.it.id"), var("temp_data.post")], "temp_data.folded")},
        {"id": "held", "name": "Halt if the fence moved under the fold",
         "condition": IS_FOLD,
         "function": halt_unless(wrote_something("temp_data.folded"))},
        # After `held`, so only a fold this run actually wrote is announced -- and N_RESULTS reads
        # `rated` off the row regardless.
        {"id": "notify_result", "name": "Tell each seat's owner how it went",
         "condition": IS_FOLD,
         "continue_on_error": True,
         "function": db_write("soma-db", N_RESULTS, [var("temp_data.it.id")],
                              "temp_data.notified_result")},
        {"id": "notify_rank", "name": "Tell each seat's owner a settled rank that moved",
         "condition": IS_FOLD,
         "continue_on_error": True,
         "function": db_write("soma-db", N_RANKS, [
             var("temp_data.it.id"), var("metadata.vars.settled_sigma")],
             "temp_data.notified_rank")},

        {"id": "pass", "name": "Promote and seed",
         "condition": IS_PASS,
         "function": db_write("soma-db", C_PASS, RUN_FENCE + [
             var("temp_data.it.trial_id"), var("temp_data.it.model_id"),
             var("metadata.vars.prior_mu"), var("metadata.vars.prior_sigma"),
             var("metadata.vars.sigma_inflation")], "temp_data.promoted")},
        {"id": "withdraw", "name": "Withdraw the predecessor's queue",
         "condition": IS_PASS,
         "function": db_write("soma-db", C_WITHDRAW_PRED, [
             var("temp_data.it.predecessor_id"), var("temp_data.it.model_id")],
             "temp_data.withdrawn")},
        # A pass that affected zero rows was decided by a concurrent run, and the version is
        # `active` either way: the key makes the two runs' notifications one.
        {"id": "notify_promoted", "name": "Tell the owner it is on the ladder",
         "condition": IS_PASS,
         "continue_on_error": True,
         "function": db_write("soma-db", N_VERSION, [var("temp_data.it.model_id")],
                              "temp_data.notified_promoted")},
        {"id": "reject", "name": "Reject, with the reason a competitor reads",
         "condition": IS_REJECT,
         "function": db_write("soma-db", C_REJECT, RUN_FENCE + [
             var("temp_data.it.trial_id"), var("temp_data.it.model_id"),
             var("temp_data.it.reason")], "temp_data.rejected")},
        {"id": "notify_rejected", "name": "Tell the owner the trial failed",
         "condition": IS_REJECT,
         "continue_on_error": True,
         "function": db_write("soma-db", N_VERSION, [var("temp_data.it.model_id")],
                              "temp_data.notified_rejected")},
    ],
}

PAIR = {
    "workflow_id": "tb-pair-run",
    "name": "Clock: pair",
    "description": (
        "Inserts the matches the ladder wants. Reads the roster epoch, the demand document and the "
        "waiting trials at sweep 0, asks the pairing plugin to fill the room, and puts the trial "
        "pairings first in the plan so a candidate waiting on its trial is never crowded out by the "
        "queue. Every insert checks the epoch FOR SHARE and halts the run if it has moved -- that, "
        "not a run fence, is pair's guarantee: a stale run can overfill by at most one run's worth, "
        "which the depth target bounds and the next run absorbs, but it can never pair a version "
        "that has left. The trial pairings are chosen in SQL, not by the plugin: the choice is "
        "mechanical and must not depend on the plugin's state."
    ),
    "tags": ["pkg:soma"],
    "condition": True,
    "loop": {"counter": "i", "max": 200},
    "tasks": [
        first_sweep({"id": "game", "name": "Resolve the game",
                     "function": db_read("soma-db", P_GAME, [var("metadata.vars.game")],
                                         "temp_data.game")}),
        first_sweep({"id": "epoch", "name": "Read the roster epoch",
                     "function": db_read("soma-db", P_EPOCH, [], "temp_data.roster")}),
        first_sweep({"id": "demand", "name": "Read demand, the pool and the room",
                     "function": db_read("soma-db", P_DEMAND_DOC, [
                         var("temp_data.game.0.id"),
                         var("metadata.vars.burst"),
                         var("metadata.vars.steady_cap"),
                         var("metadata.vars.settled_sigma"),
                         var("metadata.vars.pair_depth_target"),
                         var("metadata.vars.cross_class_fraction")], "temp_data.demand")}),
        # NO BOARD IN PLAY IS A DESIGNED HALT, not an error. `tb.pairing` refuses an empty board
        # list (NO_MAPS), rightly, so without this every tick of a fresh platform -- and of any
        # season whose boards an admin has all switched off -- logged an ERROR until a board was
        # enabled. A trial needs a board too, so nothing is lost by stopping here. The test is on a
        # map's `id`, a string, because a bare object is not a boolean to a filter.
        first_sweep({"id": "boards", "name": "Halt while no board is in play",
                     "function": halt_unless(
                         {"!!": [var("temp_data.demand.0.body.limits.maps.0.id")]})}),
        first_sweep({"id": "trials", "name": "Find candidates waiting for a trial",
                     "function": db_read("soma-db", P_TRIALS, [
                         var("temp_data.game.0.id"),
                         var("metadata.vars.repair_cap")], "temp_data.trials")}),
        first_sweep({"id": "pair", "name": "Choose the room's pairings",
                     "function": {"name": "tb.pairing.pair", "input": {
                         # The boards and `cross_class_fraction` are inside demand.limits: the
                         # boards are the season's enabled maps and nothing else, the
                         # fraction the season's with the deploy's [vars] as the fallback. One
                         # document, one source.
                         "demand": var("temp_data.demand.0.body"),
                         "seed": var("metadata.trigger.occurrence_id"),
                         "output": "temp_data.paired"}}}),
        first_sweep({"id": "plan", "name": "Trials first, then the room",
                    "function": {"name": "map", "input": {"mappings": [
                        {"path": "temp_data.plan",
                         "logic": {"merge": [var("temp_data.trials.0.body.pairings"),
                                             var("temp_data.paired.pairings")]}},
                        {"path": "temp_data.n",
                         "logic": {"+": [var("temp_data.trials.0.body.n"),
                                         var("temp_data.paired.n")]}}]}}}),
        {"id": "more", "name": "Stop when the plan runs out",
         "function": halt_unless({"<": [var("temp_data.i"), var("temp_data.n")]})},
        {"id": "item", "name": "Take pairing i",
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.it",
              "logic": {"val": ["temp_data", "plan", {"val": ["temp_data", "i"]}]}},
             {"path": "temp_data.pairing_id", "logic": {"random": ["uuid"]}}]}}},
        {"id": "insert", "name": "Insert the match and its seats",
         "function": db_write("soma-db", P_INSERT, [
             var("temp_data.roster.0.epoch"), var("metadata.vars.game"),
             var("temp_data.it.seed"), var("temp_data.it.map"),
             var("temp_data.it.seats"), var("temp_data.it.trial"),
             var("temp_data.pairing_id"),
             var("metadata.vars.forfeit_strikes")], "temp_data.inserted")},
        {"id": "held", "name": "Halt if the roster moved under the insert",
         "function": halt_unless(wrote_something("temp_data.inserted"))},
    ],
}


# ====================================================================== admission
#
# Admission writes one row per item and needs no run fence. Count claims one because it is the only
# writer of a ladder and must prove a stale occurrence wrote nothing; admission's per-row claim is
# already the mutual exclusion, and is better here -- a run that dies mid-batch releases what it
# had not reached at once, and the row it was holding after admit_timeout_s.

# --- reject what has run out of attempts, before claiming anything. Separate
# from the claim so the last attempt is recorded and the rejection can name it.
#
# The token it stamps is THIS RUN'S, not the lapsed claim's and not NULL. Nothing reads a token on a
# rejected row -- every claim, batch and verdict statement requires `testing` -- so the column is
# free to say which run decided the row, and N_EXPIRED is the statement that needs to know.
A_EXPIRE = """
UPDATE model_versions
   SET status = 'rejected', reject_reason = 'TIMED_OUT',
       admit_started_at = NULL, admit_token = ($3)::uuid
 WHERE status = 'testing' AND admit_attempts >= ($1)::int
   AND (admit_started_at IS NULL
        OR admit_started_at < now() - (($2)::int * interval '1 second'))
"""

# --- take up to $2 submissions, stamping this run's token on each. SKIP LOCKED
# so two overlapping runs take disjoint sets rather than one blocking on the other. Oldest first,
# so a submission that has already burned an attempt does not jump ahead of one that has not.
A_CLAIM = """
UPDATE model_versions m
   SET admit_started_at = now(), admit_attempts = m.admit_attempts + 1, admit_token = ($1)::uuid
 WHERE m.id IN (SELECT c.id FROM model_versions c
                 WHERE c.status = 'testing'
                   AND (c.admit_started_at IS NULL
                        OR c.admit_started_at < now() - (($3)::int * interval '1 second'))
                 ORDER BY c.created_at
                 LIMIT ($2)::int
                 FOR UPDATE SKIP LOCKED)
"""

# --- everything the walk needs, in one read. The budget comes from the GAME'S
# MANIFEST, not from [vars]: adapter_ops_max is the cartridge's declaration and is per game by
# construction, so a second cartridge is content and not a config change.
#
# `model`, `artifact_key` and `manifest_key` are DERIVED from the version id: the id
# is the model id and the keys are where Soma's presigned PUTs told the competitor to upload. Two
# rows can never disagree about where a version's bytes are, because neither row says.
A_BATCH_DOC = """
SELECT json_build_object(
         'n', count(*),
         'items', coalesce(json_agg(json_build_object(
                    'model_id', v.id,
                    'model', ($5)::text || v.id::text,
                    'weights_hash', v.weights_hash, 'manifest_hash', v.manifest_hash,
                    'artifact_key', v.artifact_key,
                    'manifest_key', regexp_replace(v.artifact_key, 'model\\.onnx$', 'manifest.json'),
                    'attempt', v.admit_attempts,
                    'budget_ops', coalesce((se.rules -> 'graph' ->> 'adapter_ops_max')::bigint,
                                           (g.manifest -> 'budgets' ->> 'adapter_ops_max')::bigint),
                    -- THE GAME AND HOW MANY, NEVER THE SET. The reference set is ~500 KB of JSON
                    -- and ~150k nodes parsed, and every copy a workflow makes of it is kept twice
                    -- over (the audit trail's old and new values, then the trace's). Carried per
                    -- item it rode the batch, `temp_data.it`, the probe's payload and the probe's
                    -- reply: a burst of ten submissions held ~3 GB. The probe reads one at a time.
                    'game_id', g.id,
                    'observations_n', CASE WHEN jsonb_typeof(g.reference_observations) = 'array'
                                           THEN jsonb_array_length(g.reference_observations)
                                           ELSE 0 END,
                    -- THE SEASON'S GRAPH RULES, CARRIED PER ITEM. Every one of these was a
                    -- metadata.vars read inside the judge task, which is one value for a whole run;
                    -- an item's own rules are the item's, and they come from THE VERSION'S OWN
                    -- SEASON, so the re-validation sweep judges an older version by the rules it
                    -- was admitted under rather than by the live season's.
                    'opset_min', coalesce((se.rules -> 'graph' ->> 'opset_min')::int, ($2)::int),
                    'opset_max', coalesce((se.rules -> 'graph' ->> 'opset_max')::int, ($3)::int),
                    'op_allowlist', coalesce(
                        -- INTERSECTED with the platform's list, never replacing it: a season that
                        -- allowed an operator this runtime cannot execute would admit a model that
                        -- then fails at play, which is a rejection deferred to the worst possible
                        -- moment. A season may only narrow.
                        (SELECT jsonb_agg(o) FROM jsonb_array_elements_text(($4)::jsonb) AS o
                          WHERE o IN (SELECT jsonb_array_elements_text(
                                          se.rules -> 'graph' -> 'op_allowlist'))),
                        ($4)::jsonb),
                    'params_max',   (se.rules -> 'graph' ->> 'params_max')::bigint,
                    'infer_us_max', (se.rules -> 'graph' ->> 'infer_us_max')::bigint,
                    -- What judge tests to know the rules reached it at all. Without it a null
                    -- ceiling reads as "no ceiling" through `{"<": [x, null]}`, which is FALSY --
                    -- so every submission would pass every gate, silently.
                    'rules_ok', se.id IS NOT NULL)
                  ORDER BY v.created_at), '[]'::json)) AS body
  FROM model_versions v
  JOIN games g   ON g.id = v.game_id
  JOIN seasons se ON se.id = v.season_id
 WHERE v.admit_token = ($1)::uuid AND v.status = 'testing'
"""

# --- the manifest the competitor uploaded, hashed HERE rather than trusted. The
# schema's CHECK recomputes the same sha256 over the stored text, so a mismatch that reached
# `verify` would be a constraint violation -- a 500 and a burned attempt for what is an ordinary
# competitor mistake. This turns it into a reason word.
A_MANIFEST_OK = """
SELECT ('sha256:' || encode(sha256(convert_to(($2)::text, 'UTF8')), 'hex') = ($1)::text) AS ok,
       length(($2)::text) AS bytes
"""

# --- The smallest class whose cap the measured size fits, against the version's OWN season.
# A statement rather than a JSONLogic reduce: reduce binds `current` and `accumulator` through the
# `val` operator only, so a `var` inside one yields null -- a wrong class that looks like an absent
# one. No class fitting returns null, which judge reads as TOO_LARGE.
A_CLASSIFY = """
SELECT (SELECT e ->> 'class'
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint
           -- classes.allow NARROWS the season's table: a class the season does not offer is not a
           -- landing place, so a model that measures into it finds no class and is refused. The
           -- word judge answers with is CLASS_NOT_OFFERED and not TOO_LARGE -- the model is not too
           -- large, this season simply is not running that class.
           AND season_admits_class(s, (e ->> 'class')::ladder)
         ORDER BY (e ->> 'max_bytes')::bigint
         LIMIT 1) AS cls,
       -- Whether ANY class of the season's full table would have fitted. It is what tells the two
       -- refusals apart: fits nothing at all is TOO_LARGE, fits something the season is not running
       -- is CLASS_NOT_OFFERED.
       (SELECT count(*) > 0
          FROM seasons s, jsonb_array_elements(s.weight_classes) AS e
         WHERE s.id = v.season_id AND (e ->> 'max_bytes')::bigint >= ($2)::bigint) AS fits_any
  FROM model_versions v
 WHERE v.id = ($1)::uuid
"""

# --- testing -> verified, under the claim. `AND admit_token = $9` is the claim
# honoured at the write: a run whose claim lapsed while it was verifying affects zero rows and
# writes nothing, without halting -- the run that owns the item now redoes the work.
#
# A BASELINE LANDS `disabled`, NOT `verified`. It is admitted by exactly this walk -- an admin
# uploads it into a season the way a competitor submits -- but it has no trial, because it is what a
# trial is played against, and it is out of play until an admin enables it, as an uploaded map is.
# `verified` would put it in P_TRIALS' candidate set, where it would wait for a trial for ever.
#
# The schema's model_versions_past_testing_has_contents refuses a row past `testing` without
# weights_hash, manifest_hash, orion_version, artifact_key and weight_class, so a verdict that
# forgot one is a constraint violation rather than a half-verified version pair happily seats.
# model_versions_manifest_matches_hash recomputes sha256 over the stored text, which is why the
# manifest is checked against its declared hash before it gets here.
A_VERIFY = """
UPDATE model_versions
   SET status = CASE WHEN EXISTS (SELECT 1 FROM models e JOIN users u ON u.id = e.owner_id
                                   WHERE e.id = model_versions.model_id AND u.role = 'baseline')
                     THEN 'disabled'::model_status ELSE 'verified'::model_status END,
       weight_class = ($2)::ladder,
       size_bytes = ($3)::bigint, param_count = ($4)::bigint,
       -- ($5)::float8::bigint AND NOT ($5)::bigint. The probe measures `inference_ms`, which is
       -- fractional, and reports microseconds as `1000 * ms` -- so what arrives here is a JSON
       -- number with a decimal part, and binding one to an INT8 placeholder is refused by the
       -- driver before Postgres sees it: "expected an integer, got a number". That killed the
       -- WHOLE RUN rather than the item, because verify is not continue_on_error, so the claim was
       -- never released, `reject` and `giveback` never ran, and the next sweep re-walked a model
       -- that was already registered -- 409 on register, 404 on activate, PROBE_UNREACHABLE for
       -- ever. Rounding belongs here rather than in the probe: the column is microseconds as a
       -- whole number, and the measurement is not.
       infer_us = ($5)::float8::bigint,
       manifest = ($6)::text, orion_version = ($7)::text,
       probe_dims = ($9)::jsonb,
       admit_started_at = NULL, reject_reason = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($8)::uuid
"""

# --- the twin. A rejection is terminal; the competitor submits again,
# which is a new row.
A_REJECT = """
UPDATE model_versions
   SET status = 'rejected', reject_reason = ($2)::text,
       admit_started_at = NULL
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($3)::uuid
"""

# --- a fault that is OURS releases the claim and GIVES THE ATTEMPT BACK.
# Decrementing keeps admit_attempts_max a count of real attempts: a store that is down for an hour
# must not consume a competitor's three tries.
#
# EXCEPT A PROBE THAT FAILED ON A MODEL THIS NODE ADMITTED AND ACTIVATED ($3). By then the store,
# the node and the admission all answered, so what is left is mostly the submission: a
# `channel_call` fails whole on any task error in the child, `continue_on_error` or not (Orion
# 1.8.1's RunOutcome::WorkflowErrors), so an adapter that fails one observation arrives here as
# no probe at all, exactly as a timeout does. Refunded, that was a retry every tick for ever; kept,
# a load spike costs one of three tries and a broken adapter expires TIMED_OUT.
A_RELEASE = """
UPDATE model_versions
   SET admit_started_at = NULL, admit_token = NULL,
       admit_attempts = CASE WHEN ($3)::boolean THEN admit_attempts
                             ELSE greatest(admit_attempts - 1, 0) END
 WHERE id = ($1)::uuid AND status = 'testing' AND admit_token = ($2)::uuid
"""


ADMIT = {
    "workflow_id": "tb-admit-run",
    "name": "Clock: admit",
    "description": (
        "What moves a submission off `testing`. Per item it "
        "reads the manifest the competitor uploaded to the models bucket and checks it "
        "against the hash they declared, registers the model on THIS node by reference and digest "
        "-- the node fetches the object and re-hashes it, so a row that lies fails admission -- "
        "runs admission synchronously, activates it, plays it over the game's reference "
        "observations through the probe channel, applies the platform's policy to the stats, and "
        "writes one verdict. It never fetches a competitor's bytes over the internet: the bytes "
        "are in the bucket because the competitor PUT them there through a presigned URL Soma "
        "minted, and Orion's storage connector is what reads them. The weight class is the "
        "season's, picked by `classify` as the smallest class whose cap S' fits; no class fitting "
        "is TOO_LARGE. A baseline an admin uploaded into a season walks the same path and "
        "lands `disabled` rather than `verified`: it has no trial, and it is out of play until an "
        "admin enables it. The claim is the fence -- there is no run fence, because admission writes "
        "one row per item and a per-row claim is already the mutual exclusion. The branch that "
        "matters is on `fault`: a competitor's mistake rejects the version and OUR failure "
        "releases the claim and gives the attempt back -- except a probe that failed on a model "
        "this node activated, which keeps it, so a probe that never answers expires rather than "
        "retrying for ever. What the walk registered it deletes again, so every walk starts from "
        "nothing on the node. Every verdict, and every expiry this run "
        "stamped with its token, is then told to the owner by a keyed statement that may fail "
        "without failing the walk."
    ),
    "tags": ["pkg:soma"],
    "condition": True,
    "loop": {"counter": "i", "max": 64},
    "tasks": [
        first_sweep({"id": "token", "name": "This run\'s claim token",
                     "function": {"name": "map", "input": {"mappings": [
                         {"path": "temp_data.token", "logic": {"random": ["uuid"]}}]}}}),
        first_sweep({"id": "expire", "name": "Reject what has run out of attempts",
                     "function": db_write("soma-db", A_EXPIRE, [
                         var("metadata.vars.admit_attempts_max"),
                         var("metadata.vars.admit_timeout_s"),
                         var("temp_data.token")], "temp_data.expired")}),
        first_sweep({"id": "claim", "name": "Claim up to admit_batch submissions",
                     "function": db_write("soma-db", A_CLAIM, [
                         var("temp_data.token"), var("metadata.vars.admit_batch"),
                         var("metadata.vars.admit_timeout_s")], "temp_data.claimed")}),
        first_sweep({"id": "batch", "name": "Read what this run claimed",
                     "function": db_read("soma-db", A_BATCH_DOC, [
                         var("temp_data.token"),
                         var("metadata.vars.opset_min"),
                         var("metadata.vars.opset_max"),
                         var("metadata.vars.op_allowlist"),
                         var("metadata.vars.model_prefix")], "temp_data.batch")}),
        # Only when the expiry wrote something: N_EXPIRED finds its rows by token, which no index
        # serves, and almost every run expires nothing.
        {"id": "notify_expired", "name": "Tell the owners what just timed out",
         "condition": {"and": [{"==": [var("temp_data.i"), 0]},
                               wrote_something("temp_data.expired")]},
         "continue_on_error": True,
         "function": db_write("soma-db", N_EXPIRED, [var("temp_data.token")],
                              "temp_data.notified_expired")},
        {"id": "more", "name": "Stop when the work runs out",
         "function": halt_unless({"<": [var("temp_data.i"),
                                        var("temp_data.batch.0.body.n")]})},
        {"id": "item", "name": "Take submission i, and clear the last one",
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.it",
              "logic": {"val": ["temp_data", "batch", 0, "body", "items",
                                {"val": ["temp_data", "i"]}]}},
             # temp_data survives a sweep, so every per-item slot is cleared here: a task skipped
             # this time round would otherwise be read at the PREVIOUS submission's value. The one
             # that matters is `admitted`, which gates the verdict.
             # CLEARED WITH False, NOT None. dataflow-rs skips a mapping whose logic evaluates to
             # null (`map.rs`: `if matches!(transformed_value, OwnedDataValue::Null) { continue }`),
             # so `{"logic": null}` writes NOTHING and the slot silently keeps the last sweep's
             # value -- the exact bug this block exists to prevent. False is falsy to every
             # condition here and reads through as null, so the intent survives and the write
             # happens.
             {"path": "temp_data.head", "logic": False},
             {"path": "temp_data.man", "logic": False},
             {"path": "temp_data.mtext", "logic": False},
             {"path": "temp_data.signed", "logic": False},
             {"path": "temp_data.pd", "logic": False},
             {"path": "temp_data.manok", "logic": False},
             {"path": "temp_data.reg", "logic": False},
             {"path": "temp_data.created", "logic": False},
             {"path": "temp_data.charge", "logic": False},
             {"path": "temp_data.adm", "logic": False},
             {"path": "temp_data.act", "logic": False},
             {"path": "temp_data.probe", "logic": False},
             {"path": "temp_data.cls", "logic": False},
             {"path": "temp_data.size", "logic": False},
             {"path": "temp_data.ops", "logic": False},
             {"path": "temp_data.dts", "logic": False},
             {"path": "temp_data.admitted", "logic": False},
             {"path": "temp_data.reason", "logic": False},
             # A game whose manifest or reference set was never seeded cannot be admitted
             # against, and this is the one place to notice: with no observations the probe
             # answers nothing, rejecting a competitor for the platform's omission.
             # `False` AND NOT `None` FOR THE SAME REASON AS EVERY SLOT ABOVE, and this one is the
             # slot where getting it wrong stops the platform rather than one submission. The
             # normal branch of this chain is "nothing is wrong with this item", and written as
             # `None` the mapping is SKIPPED -- so `retry` keeps the PREVIOUS item's value. One
             # submission whose probe times out therefore sets `retry` for every submission behind
             # it in the batch: their tasks are all gated on `{"!": retry}`, so they are skipped
             # wholesale and `giveback` releases them untouched. `claim` orders by `created_at` and
             # `giveback` hands the attempt BACK, so the poisoned row is re-claimed first on every
             # tick, for ever, and never reaches `admit_attempts_max` to be expired. Admission
             # stops for everyone, with every clock healthy and every row looking merely slow.
             {"path": "temp_data.retry",
              "logic": {"if": [{"!": var("temp_data.it.budget_ops")}, "MANIFEST_INCOMPLETE",
                               {"!": var("temp_data.it.observations_n")}, "MANIFEST_INCOMPLETE",
                               {"!": var("temp_data.it.artifact_key")}, "MANIFEST_INCOMPLETE",
                               False]}}]}}},

        # Is the artifact even there? A submission whose upload never happened is the commonest
        # failure of the presigned-PUT contract, and it must not read like a broken model.
        {"id": "head", "name": "Is the artifact in the bucket?",
         "condition": {"!": var("temp_data.retry")},
         "continue_on_error": True,
         "function": {"name": "storage_head", "input": {
             "connector": "soma-models-internal", "key": var("temp_data.it.artifact_key"),
             "output": "temp_data.head"}}},

        {"id": "sign", "name": "Sign a GET for the manifest",
         "condition": {"and": [{"!": var("temp_data.retry")}, var("temp_data.head.exists")]},
         "continue_on_error": True,
         "function": {"name": "storage_presign", "input": {
             "connector": "soma-models-internal", "method": "GET",
             "key": var("temp_data.it.manifest_key"), "expires_in": "5m",
             "output": "temp_data.signed"}}},

        # TWICE, and deliberately. `text` is the competitor's exact bytes -- what the declared
        # hash is over, what the schema's CHECK recomputes, and what `len(manifest)` prices in S'.
        # `json` is the same object parsed, which is what the registration is rebuilt from. There
        # is no parse operator in the expression language, and re-serialising the parsed form would
        # hash a document the competitor never wrote.
        {"id": "fetch_text", "name": "The manifest, as the bytes that were uploaded",
         "condition": {"!!": var("temp_data.signed")},
         "continue_on_error": True,
         "function": http("soma-models-http", "GET",
                          {"substr": [var("temp_data.signed"),
                                      {"length": [var("metadata.vars.models_endpoint")]}]},
                          "temp_data.mtext", response_format="text")},

        {"id": "fetch", "name": "The manifest, parsed",
         "condition": {"!!": var("temp_data.mtext")},
         "continue_on_error": True,
         "function": http("soma-models-http", "GET",
                          {"substr": [var("temp_data.signed"),
                                      {"length": [var("metadata.vars.models_endpoint")]}]},
                          "temp_data.man")},

        {"id": "manifest_ok", "name": "Does it hash to what was declared?",
         "condition": {"!!": var("temp_data.mtext")},
         "function": db_read("soma-db", A_MANIFEST_OK, [
             var("temp_data.it.manifest_hash"), var("temp_data.mtext")], "temp_data.manok")},

        # WHAT THE PLATFORM REGISTERS IS NOT WHAT WAS UPLOADED. The fields are copied one by one
        # rather than the document being passed through: `name` becomes the platform's model id
        # (`tb.v<uuid>`), and a `reference` naming somebody else's bucket key -- the one field of a manifest
        # that could reach outside this version -- has nowhere to survive. `artifact` is offline
        # tooling's and is dropped with it.
        {"id": "shape", "name": "The registration, rebuilt field by field",
         "condition": {"===": [var("temp_data.manok.0.ok"), True]},
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.reg",
              "logic": {"abi": var("temp_data.man.abi"),
                        "name": var("temp_data.it.model"),
                        "version": {"??": [var("temp_data.man.version"), "1"]},
                        "format": {"??": [var("temp_data.man.format"), "onnx"]},
                        "description": {"??": [var("temp_data.man.description"), ""]},
                        "inputs": var("temp_data.man.inputs"),
                        "outputs": var("temp_data.man.outputs"),
                        "probe_dims": {"??": [var("temp_data.man.probe_dims"), {}]}}},
             {"path": "temp_data.reason",
              "logic": {"if": [var("temp_data.reason"), var("temp_data.reason"),
                               {"!": var("temp_data.man.inputs")}, "MANIFEST_INVALID",
                               {"!": var("temp_data.man.outputs")}, "MANIFEST_INVALID",
                               None]}}]}}},

        # A RESULT EXPRESSION IS REFUSED, and this is where. The platform decodes the head itself, so a
        # manifest carrying one is not merely ignored -- it is a competitor believing something
        # about the contract that is not true, and the cheapest moment to say so is now.
        {"id": "reject_result", "name": "A manifest may not decode its own head",
         "condition": {"and": [{"!!": var("temp_data.man")}, {"!!": var("temp_data.man.result")}]},
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.reason", "logic": "RESULT_NOT_ALLOWED"}]}}},

        {"id": "register", "name": "Register it on this node, by reference and digest",
         "condition": {"and": REGISTERABLE},
         "continue_on_error": True,
         "function": http("soma-node-admin", "POST", "/models", "temp_data.created",
                          REGISTRATION)},

        # A 409 IS A WALK THAT DIED BEFORE `drop`: the claim lapsed and this run holds the row now.
        # What it left cannot be walked again -- Orion activates only a `draft` version, so one
        # left `archived` 404s on `activate` for ever -- so it goes, whole, and is registered
        # afresh. `created` is written only on a 2xx, which is what makes it the test.
        {"id": "clear", "name": "Remove what a dead walk left here",
         "condition": {"and": REGISTERABLE + [{"!": var("temp_data.created")}]},
         "continue_on_error": True,
         "function": http("soma-node-admin", "DELETE",
                          {"cat": ["/models/", var("temp_data.it.model")]},
                          "temp_data.cleared", response_format="text")},
        {"id": "reregister", "name": "Register it again, from nothing",
         "condition": {"and": REGISTERABLE + [{"!": var("temp_data.created")}]},
         "continue_on_error": True,
         "function": http("soma-node-admin", "POST", "/models", "temp_data.created",
                          REGISTRATION)},

        # Admission, synchronously. `?wait=true` is what makes this a walk rather than a state
        # machine: the verdict is recorded on the row before the call returns, so there is no poll
        # loop, no timeout of ours to tune, and no half-admitted version to reconcile later.
        # Idempotent, so a re-run after a lapsed claim costs one more probe and nothing else.
        # THROUGH THE `data` ENVELOPE. Every admin reply is `{"data": {...}}`, and reading
        # `temp_data.adm.admission.state` instead finds null -- which is not "passed", so every
        # submission would be retried for ever as OUR fault, with the node reporting it admitted.
        {"id": "admit", "name": "Fetch, verify, read the graph, probe it",
         "condition": {"and": [{"!!": var("temp_data.reg")}, {"!": var("temp_data.reason")},
                               {"!": var("temp_data.retry")}]},
         "continue_on_error": True,
         "function": http("soma-node-admin", "POST",
                          {"cat": ["/models/", var("temp_data.it.model"), "/admit?wait=true"]},
                          "temp_data.adm")},

        # THE BRANCH THAT MATTERS, and it is on WHOSE FAULT rather than on the reason word. A
        # verdict of `failed` is the competitor's artifact; no verdict at all is ours.
        {"id": "sift", "name": "Refused by whose fault?",
         "condition": {"!": var("temp_data.retry")},
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.admitted",
              "logic": {"===": [var("temp_data.adm.data.admission.state"), "passed"]}},
             {"path": "temp_data.reason",
              "logic": {"if": [var("temp_data.reason"), var("temp_data.reason"),
                               var("temp_data.admitted"), None,
                               # The upload never arrived, or arrived at the wrong key.
                               {"!": var("temp_data.head.exists")}, "ARTIFACT_MISSING",
                               {"!": var("temp_data.man")}, "MANIFEST_MISSING",
                               {"!==": [var("temp_data.manok.0.ok"), True]}, "MANIFEST_MISMATCH",
                               # A verdict of `failed` names its own stage and reason; the stage is
                               # what tells a digest mismatch from a graph that will not load.
                               {"===": [var("temp_data.adm.data.admission.state"), "failed"]},
                               {"cat": [{"upper": [{"??": [var("temp_data.adm.data.admission.stage"),
                                                           "admission"]}]}, "_FAILED"]},
                               None]}},
             {"path": "temp_data.retry",
              "logic": {"if": [var("temp_data.retry"), var("temp_data.retry"),
                               var("temp_data.admitted"), None,
                               {"!": var("temp_data.reason")}, "ADMISSION_UNREACHABLE",
                               None]}}]}}},

        # Active, because `model_infer` will not run a model that is not -- and the probe below is
        # a real inference through the real handler, which is the whole point of it.
        {"id": "activate", "name": "Activate it here, for the probe",
         "condition": var("temp_data.admitted"),
         "continue_on_error": True,
         "function": http("soma-node-admin", "PATCH",
                          {"cat": ["/models/", var("temp_data.it.model"), "/status"]},
                          "temp_data.act", {"status": "active"})},

        # THE ADAPTER, against the game's reference observations. Orion's own probe runs the GRAPH
        # over zero-filled inputs; it never evaluates an adapter, so this is the only thing that
        # answers "does this submission turn an observation of this game into a move". It is a
        # channel call rather than a task loop because the observation count is the game's, not the
        # workflow's.
        {"id": "probe", "name": "The adapter, against the reference observations",
         "condition": {"and": [var("temp_data.admitted"), {"!": var("temp_data.reason")}]},
         "continue_on_error": True,
         "function": {"name": "channel_call", "input": {
             "channel": "tb-probe",
             # `data`, NOT `body`: channel_call's payload field is `data`, and an unknown input key
             # is IGNORED rather than refused. Spelt `body` (the shape `http()` takes) this task ran
             # with tb-probe's default payload -- the clock's own, which is empty -- so `init` set
             # ok=true, the `more` filter halted on sweep 0, and EVERY submission passed the adapter
             # probe without one observation being evaluated. `continue_on_error` hid it, and
             # `orion-server clippy` is what names it: correctness.unknown_input_key.
             "data": {"model": var("temp_data.it.model"),
                      "game_id": var("temp_data.it.game_id"),
                      "n": var("temp_data.it.observations_n"),
                      "budget_ops": var("temp_data.it.budget_ops")},
             "timeout_ms": var("metadata.vars.admit_deadline_ms"),
             "output": "temp_data.probe"}}},

        # S' = the bytes the node measured against a digest it re-hashed, plus the document this
        # walk forwarded. Both terms are unforgeable, and the second still prices
        # knowledge packed into the adapter -- which is what the old `S`'s adapter term was for.
        {"id": "pd", "name": "What the probe measured at, as a document",
         "condition": var("temp_data.admitted"),
         "function": {"name": "map", "input": {"mappings": [
             # `db_write` folds {"var": ..} nodes and nothing else, so a `??` written inline in
             # `params` is passed through as a literal object -- which lint catches and which would
             # otherwise store the expression instead of its value.
             {"path": "temp_data.pd",
              "logic": {"??": [var("temp_data.adm.data.stats.probe_dims"), {}]}}]}}},

        {"id": "metric", "name": "The size this season measures by",
         "condition": var("temp_data.admitted"),
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.size",
              "logic": {"+": [var("temp_data.adm.data.stats.artifact_bytes"),
                              var("temp_data.manok.0.bytes")]}}]}}},

        {"id": "classify", "name": "Which class does it measure into",
         "condition": {"and": [var("temp_data.admitted"), {"!!": var("temp_data.size")}]},
         "function": db_read("soma-db", A_CLASSIFY, [
             var("temp_data.it.model_id"), var("temp_data.size")],
             "temp_data.clsrow")},

        # THE POLICY, applied on this side of the seam. Orion reports facts -- parameters, the
        # operator set, the opset, what the probe cost -- and this layer judges them, so a
        # threshold change is a platform decision and not a redeploy of anything.
        {"id": "judge", "name": "Class, opset, operators and the budget",
         "condition": var("temp_data.admitted"),
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.cls", "logic": var("temp_data.clsrow.0.cls")},
             # A REDUCE, AND NOT A FILTER: `metadata.vars` is root scope exactly as `data` is, so
             # the allowlist read inside a filter body is null and `in [x, null]` is false -- which
             # would name every operator as disallowed. The accumulator carries it in from the
             # initial value, which IS evaluated at root scope.
             #
             # `stats.operators` is Orion 1.8.1's, and it is why this check survives the rewrite:
             # before it, the operator set was the loader's to report, and the loader is gone.
             {"path": "temp_data.ops",
              "logic": {"reduce": [
                  var("temp_data.adm.data.stats.operators"),
                  {"allow": var("accumulator.allow"),
                   "bad": {"if": [{"in": [var("current"), var("accumulator.allow")]},
                                  var("accumulator.bad"),
                                  {"merge": [var("accumulator.bad"), [var("current")]]}]}},
                  {"allow": var("temp_data.it.op_allowlist"), "bad": []}]}},
             {"path": "temp_data.reason",
              "logic": {"if": [var("temp_data.reason"), var("temp_data.reason"),
                               {"!": var("temp_data.size")}, None,
                               # The season is not running the class this measured into -- which is
                               # not the same refusal as being too large for every class there is,
                               # and must not read like it.
                               {"and": [{"!": var("temp_data.cls")},
                                        var("temp_data.clsrow.0.fits_any")]},
                               "CLASS_NOT_OFFERED",
                               {"!": var("temp_data.cls")}, "TOO_LARGE",
                               {"<": [var("temp_data.adm.data.stats.opset"),
                                      var("temp_data.it.opset_min")]}, "OPSET_UNSUPPORTED",
                               {">": [var("temp_data.adm.data.stats.opset"),
                                      var("temp_data.it.opset_max")]}, "OPSET_UNSUPPORTED",
                               {">": [{"length": [var("temp_data.ops.bad")]}, 0]}, "OP_NOT_ALLOWED",
                               # Null means the season set no ceiling, so the test is guarded --
                               # `{">": [x, null]}` is FALSY, which would read as "under the
                               # ceiling" and pass, but only by luck. The guard says what is meant.
                               {"and": [{"!!": var("temp_data.it.params_max")},
                                        {">": [var("temp_data.adm.data.stats.parameters"),
                                               var("temp_data.it.params_max")]}]},
                               "PARAMS_EXCEEDED",
                               # The probe's verdict on the adapter. ADAPTER_OVER_BUDGET is this
                               # layer's word, not the engine's: "too expensive" and "malformed"
                               # must not read the same.
                               {"and": [{"!!": var("temp_data.probe")},
                                        {"!": var("temp_data.probe.ok")},
                                        var("temp_data.probe.over_budget")]},
                               "ADAPTER_OVER_BUDGET",
                               {"and": [{"!!": var("temp_data.probe")},
                                        {"!": var("temp_data.probe.ok")}]},
                               {"??": [var("temp_data.probe.reason"), "ADAPTER_INVALID"]},
                               # graph.infer_us_max, and NULL IN EVERY SEASON THE PLATFORM SHIPS.
                               # There is no platform compute cap on purpose: wall clock
                               # belongs to the admission host, so a season that sets this is
                               # choosing admission whose verdicts depend on a noisy neighbour.
                               {"and": [{"!!": var("temp_data.it.infer_us_max")},
                                        {">": [var("temp_data.probe.infer_us_max"),
                                               var("temp_data.it.infer_us_max")]}],
                                }, "TOO_SLOW",
                               None]}},
             {"path": "temp_data.retry",
              "logic": {"if": [var("temp_data.retry"), var("temp_data.retry"),
                               # A version whose season could not be read is the platform's fault
                               # and never the competitor's -- the same class of guard as
                               # MANIFEST_INCOMPLETE, and for the same reason: without it every
                               # ceiling below is null, every comparison against null is falsy, and
                               # every submission passes every gate in silence.
                               {"!": var("temp_data.it.rules_ok")}, "SEASON_RULES_INCOMPLETE",
                               {"!": var("temp_data.probe")}, "PROBE_UNREACHABLE",
                               None]}},
             # Whether `giveback` keeps the attempt: a probe that failed on a model this node
             # activated. See A_RELEASE. `act` is written only on a 2xx.
             {"path": "temp_data.charge",
              "logic": {"and": [{"===": [var("temp_data.retry"), "PROBE_UNREACHABLE"]},
                                {"!!": var("temp_data.act")}]}}]}}},

        # Whatever the verdict, and whatever this node decided: the admission node is not a player,
        # so a model left active here would be recompiled into every generation it never serves.
        # The replicas' own roster clocks are what make a version playable.
        #
        # DELETED, NOT ARCHIVED, so that every walk starts from nothing. An archived model cannot
        # be walked again: `register` 409s on the id and Orion activates only a `draft`, so a retry
        # after a probe that timed out 404'd on `activate`, probed a model that was not active, was
        # given back as PROBE_UNREACHABLE, and did it again every tick for ever -- 68 ERROR lines a
        # tick, with the attempt refunded each time so it never expired.
        # `text`, here and on `clear`: a delete answers 204 with no body, and the default `json`
        # fails to parse nothing -- an ERROR on every walk, and a kept trace for every admission.
        {"id": "drop", "name": "Leave nothing of it on the admission node",
         "condition": {"!!": var("temp_data.created")},
         "continue_on_error": True,
         "function": http("soma-node-admin", "DELETE",
                          {"cat": ["/models/", var("temp_data.it.model")]},
                          "temp_data.dropped", response_format="text")},

        # The class is required rather than merely written: it is the one field that only exists if
        # admission answered, so requiring it here is what stops a half-verified row reaching the
        # schema's CHECK as a 500.
        {"id": "verify", "name": "testing -> verified (a baseline: disabled)",
         "condition": {"and": STILL_GOOD + [{"!!": var("temp_data.cls")}]},
         "function": db_write("soma-db", A_VERIFY, [
             var("temp_data.it.model_id"), var("temp_data.cls"),
             var("temp_data.size"), var("temp_data.adm.data.stats.parameters"),
             var("temp_data.probe.infer_us_max"), var("temp_data.mtext"),
             var("metadata.vars.orion_version"), var("temp_data.token"),
             var("temp_data.pd")],
             "temp_data.verified")},

        {"id": "reject", "name": "Reject, with the word a competitor reads",
         "condition": {"!!": var("temp_data.reason")},
         "function": db_write("soma-db", A_REJECT, [
             var("temp_data.it.model_id"), var("temp_data.reason"),
             var("temp_data.token")], "temp_data.rejected")},

        {"id": "giveback", "name": "Our fault: release the claim and the attempt",
         "condition": {"!!": var("temp_data.retry")},
         "function": db_write("soma-db", A_RELEASE, [
             var("temp_data.it.model_id"), var("temp_data.token"), var("temp_data.charge")],
             "temp_data.released")},

        # The verdict, told to its owner -- whichever of `verify` and `reject` wrote it, read off
        # the row. A claim that lapsed mid-walk wrote nothing, so this inserts nothing for it and
        # the run that owns the item now tells it instead; a given-back item is still `testing`.
        {"id": "notify", "name": "Tell the owner the verdict",
         "condition": {"!": var("temp_data.retry")},
         "continue_on_error": True,
         "function": db_write("soma-db", N_VERSION, [var("temp_data.it.model_id")],
                              "temp_data.notified")},
    ],
}


# --- observation i of a game's reference set. `->` on a jsonb array is null past its end, which the
# probe never reaches: its `more` filter stops at the count the batch read.
PR_OBS = """
SELECT g.reference_observations -> ($2)::int AS obs
  FROM games g
 WHERE g.id = ($1)::uuid
"""


# --- the probe channel. One `model_infer` per reference observation, looped, because the number of
# observations is the GAME'S and a task list is fixed. It answers the one question Orion's own
# admission cannot: does this submission's adapter turn an observation of this game into a tensor
# the graph accepts, inside the budget.
PROBE = {
    "workflow_id": "tb-probe-run",
    "name": "Probe an adapter",
    "description": (
        "Run an admitted model over each of the game's reference observations and report what it "
        "cost. Orion's admission probe runs the GRAPH over zero-filled inputs and never evaluates "
        "an adapter; this is what exercises the adapter, the shapes it produces and the budget it "
        "spends. `ops` and `peak_ops` are Orion 1.8.1's (#324): before them a budget could only be "
        "set by argument, and a competitor could not be told what theirs cost."
    ),
    "tags": ["pkg:soma"],
    "condition": True,
    "loop": {"counter": "i", "max": 64},
    "tasks": [
        # THE INPUT ARRIVES AS A PAYLOAD, NOT AS `data`. `channel_call` puts its `data` argument in
        # the child's PAYLOAD (execute_admitted builds the message with `.payload_json`), exactly as
        # an HTTP body would arrive, and a payload is not in the expression context until something
        # parses it. Without this task every read below resolved to nothing: `length` of a missing
        # value FAILED the `init` task with a 500, the caller's `continue_on_error` swallowed it,
        # and the admit walk saw no probe at all -- PROBE_UNREACHABLE on every submission, for ever.
        #
        # ONCE, ON SWEEP 0, because `data` survives a sweep exactly as `temp_data` does, and every
        # write keeps a deep copy of the old value and the new one in the message's audit trail
        # (dataflow-rs's `capture_changes`, which Orion leaves on). The request is small now -- the
        # reference set is read one observation a sweep, below -- but it was the whole set once,
        # and a parse a sweep then held ~128 copies of it.
        first_sweep({"id": "parse", "name": "Read the request",
                     "function": {"name": "parse_json",
                                  "input": {"source": "payload", "target": "in"}}}),
        first_sweep({"id": "init", "name": "Open the walk",
                     "function": {"name": "map", "input": {"mappings": [
                         {"path": "temp_data.n", "logic": var("data.in.n")},
                         {"path": "data.ok", "logic": True},
                         {"path": "data.over_budget", "logic": False},
                         {"path": "data.reason", "logic": None},
                         {"path": "data.ops_max", "logic": 0},
                         {"path": "data.infer_us_max", "logic": 0},
                         {"path": "data.checked", "logic": 0}]}}}),
        {"id": "more", "name": "Stop when the observations run out",
         "function": halt_unless({"<": [var("temp_data.i"), var("temp_data.n")]})},
        # ONE OBSERVATION A SWEEP, FROM THE DATABASE, so neither this message nor the caller's ever
        # holds the set: what a sweep keeps is one observation, and the audit trail's copy of it.
        {"id": "pick", "name": "Take observation i",
         "function": db_read("soma-db", PR_OBS, [var("data.in.game_id"), var("temp_data.i")],
                             "temp_data.picked")},
        {"id": "reset", "name": "Clear the last inference",
         "function": {"name": "map", "input": {"mappings": [
             {"path": "temp_data.out", "logic": False},
             {"path": "temp_data.st", "logic": False}]}}},
        # `continue_on_error`, so an inference that answers with the wrong head is tallied below
        # as ADAPTER_INVALID or HEAD_UNREADABLE. AN INFERENCE THAT FAILS OUTRIGHT IS NOT: the
        # error is still recorded on the message, and `channel_call` fails whole on any recorded
        # error, so the caller sees no probe at all -- which is why A_RELEASE charges the attempt.
        {"id": "infer", "name": "One inference",
         "continue_on_error": True,
         "function": {"name": "model_infer", "input": {
             "model": var("data.in.model"),
             "input": var("temp_data.picked.0.obs"),
             "output": "temp_data.out",
             "raw": True,
             "stats_output": "temp_data.st"}}},
        {"id": "tally", "name": "What it cost, and whether it answered",
         "function": {"name": "map", "input": {"mappings": [
             {"path": "data.checked", "logic": {"+": [var("data.checked"), 1]}},
             {"path": "data.ops_max",
              "logic": {"if": [{">": [{"??": [var("temp_data.st.peak_ops"), 0]},
                                      var("data.ops_max")]},
                               var("temp_data.st.peak_ops"), var("data.ops_max")]}},
             {"path": "data.infer_us_max",
              "logic": {"if": [{">": [{"*": [1000, {"??": [var("temp_data.st.inference_ms"), 0]}]},
                                      var("data.infer_us_max")]},
                               {"*": [1000, var("temp_data.st.inference_ms")]},
                               var("data.infer_us_max")]}},
             # The platform decodes the head, not the manifest, so the probe checks the shape it
             # will gather from rather than merely that something came back.
             {"path": "temp_data.rank",
              "logic": {"if": [{"!": var("temp_data.out.policy")}, 0,
                               {"length": [{"shape": [var("temp_data.out.policy")]}]}]}},
             {"path": "data.ok",
              "logic": {"and": [var("data.ok"), {"!!": var("temp_data.out.policy")},
                                {"in": [var("temp_data.rank"), [2, 4]]}]}},
             {"path": "data.over_budget",
              "logic": {"or": [var("data.over_budget"),
                               {"and": [{"!!": var("data.in.budget_ops")},
                                        {">": [{"??": [var("temp_data.st.peak_ops"), 0]},
                                               var("data.in.budget_ops")]}]}]}},
             {"path": "data.reason",
              "logic": {"if": [var("data.reason"), var("data.reason"),
                               {"!": var("temp_data.out.policy")}, "ADAPTER_INVALID",
                               {"!": {"in": [var("temp_data.rank"), [2, 4]]}}, "HEAD_UNREADABLE",
                               None]}}]}}},
    ],
}


WORKFLOWS = [WITHDRAW, COUNT, PAIR, ADMIT, PROBE]


def group_runs(tasks: list) -> list:
    """Collapse a run of consecutive tasks sharing one condition into a task group.

    A clock's task list is mostly `first_sweep()` runs, and written flat each one re-evaluates the
    same condition once per member -- `orion-server clippy` reports the whole set as
    perf.redundant_step_condition. A group carries the condition ONCE, on entry: a falsy result
    skips the span without evaluating the members' conditions, which is why stripping them from
    the members is equivalent rather than merely similar.

    Two runs are left alone on purpose:
      * a run holding a `terminal` member -- terminal is about position, and a group has its own
        terminal covering the whole span, so folding one in would change where the workflow ends;
      * a run of one, which is not a duplication.
    """
    out, i = [], 0
    while i < len(tasks):
        cond = tasks[i].get("condition")
        j = i
        if cond is not None and not tasks[i].get("terminal"):
            # A terminal member ends the run and is folded in, because `terminal` on a group ends
            # the workflow after the whole span -- identical when it is the last member, and only
            # then. A terminal step anywhere earlier would move where the workflow ends, so the
            # run stops before it.
            while (j + 1 < len(tasks) and tasks[j + 1].get("condition") == cond):
                j += 1
                if tasks[j].get("terminal"):
                    break
        if j > i:
            members = []
            for t in tasks[i:j + 1]:
                t = dict(t)
                t.pop("condition")
                members.append(t)
            # Canonical key order for a group: id, name, description, condition, terminal, tasks.
            group = {"id": f"when_{members[0]['id']}", "condition": cond}
            if members[-1].pop("terminal", None):
                group["terminal"] = True
            group["tasks"] = members
            out.append(group)
        else:
            out.append(tasks[i])
            j = i
        i = j + 1
    return out


def grouped(doc: dict) -> dict:
    doc = dict(doc)
    doc["tasks"] = group_runs(doc["tasks"])
    return doc


def require_orion_server() -> None:
    """The formatter is part of the build, so the wrong one is a wrong build, not a style nit."""
    if shutil.which("orion-server") is None:
        sys.exit("orion-server is not on PATH -- it formats what this script writes")
    first = subprocess.run(["orion-server", "--version"], capture_output=True, text=True,
                           check=True).stdout.splitlines()[0].split()
    if len(first) < 2 or not first[1].startswith("1.8."):
        sys.exit(f"orion-server {' '.join(first[1:2])} is not 1.8.x: its house style is not this "
                 "repository's, and --check would report every file as drifted")


def outputs() -> list[tuple[pathlib.Path, str]]:
    docs = [(PKG / "workflows" / f"{w['workflow_id']}.json", grouped(w)) for w in WORKFLOWS]
    docs += [(PKG / "channels" / f"{c['channel_id']}.json", c) for c in CHANNELS]
    require_orion_server()
    # Written to a scratch tree and formatted there, so `--check` never touches the committed
    # files and a formatter failure leaves them as they were.
    with tempfile.TemporaryDirectory(prefix="gen-clocks.") as tmp:
        scratch = pathlib.Path(tmp)
        staged = []
        for path, doc in docs:
            out = scratch / path.relative_to(PKG)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
            staged.append((path, out))
        subprocess.run(["orion-server", "fmt", str(scratch)], check=True,
                       stdout=subprocess.DEVNULL)
        formatted = [(path, out.read_text()) for path, out in staged]
    return formatted + [(PKG / "scripts" / "autoscaler.sql", AUTOSCALER_SQL)]


def main(check: bool) -> int:
    drifted = []
    for path, text in outputs():
        if check:
            current = path.read_text() if path.exists() else None
            if current != text:
                drifted.append(path.relative_to(PKG))
            continue
        path.write_text(text)
        print(f"    {path.relative_to(PKG)}")
    if not check:
        return 0
    for path in drifted:
        print(f"    {path} does not match the generator")
    print(f"==> {len(drifted)} file(s) drifted" if drifted else "==> generated files are current")
    return 1 if drifted else 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv[1:]))
