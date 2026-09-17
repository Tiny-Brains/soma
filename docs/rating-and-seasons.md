# Rating and seasons

> **These pages were `jodi/docs/` until 16 September 2026**, when the clocks and their repository
> merged into Soma. A decision, a dated entry or a quoted log that says *Jodi* means these clocks.

What count does with a match once it has folded it, and the window that work happens inside. The
rating is TrueSkill in a plugin; a season is an admin-created window per game that closes itself
when the field has settled.

The clocks are [`clocks.md`](clocks.md) — count folds and promotes, withdraw closes a season as its
second task. The numbers, and the query that measures each, are [`config.md`](config.md). The
competitor-facing half — what a rating *means*, and what a season changes for someone submitting —
is [the book](https://github.com/Tiny-Brains/web/tree/main/docs).

## 1. What this page fixes

| Settled here | Left to |
|---|---|
| the rating rules as final: one update per ladder the match feeds, equal ranks draw, ladder derivation at insert, the seed at promotion with sigma inflated and capped | the *numbers* — prior, inflation, `beta`, `tau`, the draw probability — which stay in `[vars]`, provisional, with the query that measures each (§8) |
| the dynamics factor: `tau` per update, and nothing per clock (§3) | pairing's answer to a stale top, which is a sampling question (§9) |
| what a season is: admin-created, per game, with an opening date and a last submission date, closing itself when settled; its four states; one live season per game and the configurable gap between seasons (§4) | the admin screen that creates one — the web track |
| the `seasons` table; `season_id` on `models` and `matches`; the one-active rule and the release-uniqueness rule scoped to the season (§4.5, §11) | the deploy step that declares the engine — deployment |
| the create, the close, and the deploy step's patch and release (§5); what "settled" means, as a predicate (§4.6); the baselines carried into each new season (§4.7) | — |
| the season's submission rules — a document on the season, each rule with an enable flag, two rules to begin with: unique weights across users, and a participant allowlist (§4.8) | further rules, as content in the same document |
| the six statements a season touches — pair's insert, the trial insert, the demand view, the pass, withdraw's sweep, Soma's submission — and the leaderboard by season (§6) | Soma's three new endpoints and the additive fields — §9 |
| retention as a policy table (decision 24, §7): standings forever, replays by a lifecycle rule | the bucket rule and Orion's trace retention — deployment |

---

## 2. The rating — built, and now final

Layers 01 and 02 built the rating; this section says what in it stops being provisional. Each row
names the statement that already does it.

| Rule | Where it lives | Final because |
|---|---|---|
| **Two ladders per version**: its weight class and `open`; a match feeds `open` always and its class ladder only when every seat shares one | `matches.ladders`, derived at insert — the schema §6.2 | the platform design §9's argument stands and the built ladder shows it: every counted match reached `open`, and a cross-class match reached nothing else |
| **One update per ladder per counted match**, over the seats' priors on that ladder, in finish order, under count's fence | the fold — the schema §5.2; `tb.rating.trueskill` — the clocks §8 | the reference values were matched to the last digit, and the chain constraint on `rating_events` makes a second fold of one match impossible |
| **Equal ranks draw** — decision 12 | the plugin reads only the order of ranks and which are equal | `tb.rating` proves that dense, competition-style and any order-preserving relabelling give identical output, so the numbering never reaches the update. Nothing to flip |
| **A forfeit ranks last**, by `engine_rank + seat_count`, so it cannot tie with a seat that played | Kalam's finish — the schema §4.6, 03 §4 | — |
| **The seed at promotion** — decision 3, and decision 11's *rule*: the successor inherits its predecessor's `mu` per ladder with `sigma` multiplied by `sigma_inflation` and capped at the prior; a class change seeds the class ladder from the prior; both stored on the row and as the `seq = 0` event. The predecessor is the owner's active version **in the same season** (§6.4) | the pass statement — the schema §5.3 | it ran on 8 September: sigma 0.71 → 1.43, capped at 8.33. The rule is final; the number is §8's. Variants C (lazy seed) and F (no seed) from finding 3 are **not taken**: the seed costs nothing now that count writes it, and it is also what gives pair an informed prior for the placement burst's opponents |
| **The history** — decision 22: one event per seat per ladder per counted match, `seq` the ladder's count after it, `seq = 0` the seed | `rating_events` — the schema §3.5 | 4,842 events on the running ladder, every one starting where the previous ended |
| **`conservative = mu − 3σ`** is what sorts a ladder; **provisional** is `sigma > settled_sigma`, the same number pair calls settled | the leaderboard read; the open work | one threshold, not two |

**A rating is per version, and a version is of one season**, so a rating is of one season by
construction. `ratings (model_id, ladder)` and `rating_events (model_id, ladder, seq)` are exactly
the schema's; the fold and the chain constraint do not change; a closed season's standings are its
versions' rows, which nothing writes again once its last match is counted (§4.6) and which
retention keeps forever (§7).

---

## 3. The dynamics factor — decision: `tau` per update, and nothing per clock

The risk register and the clocks §4 both say "the dynamics factor re-opens a settled version's
uncertainty *over time*", and the risk it answers is that a settled version stops being selected —
a stale rating near the top.

**What is built.** `tb.rating.trueskill` applies `tau` as TrueSkill defines it: on every update,
each seat's prior variance is widened by `tau²` before the factor graph runs
(`plugins/tb-rating/src/trueskill.rs`, the prior factor). So a version's sigma has a floor it
cannot fall below however many matches it plays, and a version that keeps playing keeps a little
doubt. That is the dynamics factor, and it is per *update*, not per day.

**Why nothing per clock.** TrueSkill's dynamics exist because a human's skill drifts between
games. **A version's weights are frozen.** Its skill against a fixed field is one number, and
every match narrows the estimate honestly. What drifts is the *field* — new versions arrive, old
ones are superseded — and TrueSkill already propagates that through the matches the new versions
play, because every update moves both seats. Inflating a settled version's sigma because a week
passed would make it `unsettled` again under the clocks §4, give it `steady_cap` matches of its own,
and those matches would teach the ladder nothing it did not know. It would also fight the two
things a settled ladder is *for* here: demand falling to zero and the replica count with it
(architecture §7), and **the season closing itself** (§4.6), which a clock that keeps re-opening
sigma would hold open forever.

**What the stale-top risk actually is.** A version rated `mu = 40` against an early, weak field
keeps that rating while a stronger field settles at 35 among themselves; nobody reaches 40, so
pair never seats the old top against a challenger. That is real, and it is bounded by the season
— a season is a fresh field, and a version's rating is only ever compared with the versions of its
own season. Within a season it is not a rating problem but a **sampling** one, and it has one
honest answer, which is pairing's: **one burst match against the ladder's top**, asked of the clocks
in §9. A new version's placement burst is spread across presets on the same prior; spending one of
its matches on the current leader of its class ladder is the cheapest possible test of whether the
top is where it belongs, and it costs no schema and no rating rule.

| | Option | What re-opens a settled version | Cost |
|---|---|---|---|
| **A** | **`tau` per update, as built; the season bounds the field** — chosen | its next match, whoever wants it as an opponent | a stale top is corrected by pairing's king match, or not at all within the season |
| B | Time-based inflation: count widens the sigma of every version idle for `reopen_days` | count's tick | information-free matches; an event with no match, which `rating_events_seed_shape` forbids; and a season that never settles, so never closes |
| C | A floor on demand: every active version keeps `steady_cap` when settled | nothing; it never settles | the same, without the pretence of a reason |

**Decision: A.** `ts_tau` stays as the plugin's per-update dynamics, provisional at
`prior_sigma / 100` (§8). No clock inflates a sigma. The risk register's row moves from "the
dynamics factor" to "pairing's king match".

---

## 4. Seasons

### 4.1 What a season is — the four rules

**A season is a competition window for one game, created by an admin.** It has an opening date,
a last submission date, and an end it reaches by itself. In the owner's words, restated as rules
the statements enforce:

1. **An admin creates a season for each game**, with its **submission window** — the date
   submissions open and the date they close — and its rules (§4.8). Nothing creates one
   automatically — not a clock, not a deploy. The create (§5.1) is an admin endpoint on Soma.
2. **A submission belongs to a season.** `models.season_id` is `NOT NULL`, stamped by
   `POST /v1/submissions` from the game's live season, and refused when there is none, when it
   is not inside its window, or when a season rule refuses it (§6.6). A version plays only in its season, and its predecessor is its owner's active
   version in that season. The same release may be entered again in the next season.
3. **Seasons of a game do not overlap, and there is a minimum gap between them.** At most one
   season of a game is *live* (not closed) at any time — a partial unique index, not a check in
   code — and a new season's opening date must be at least `season_gap_days` (default 1,
   configurable) after the previous season's close. Since a season closes at a time nobody knows
   in advance (rule 4), the next one can be created only once the previous has closed. The gap
   is measured to the new season's submission opening date.
4. **A season has a last submission date, and ends automatically when its scores are settled.**
   After the submission window closes no version enters; the versions in it keep playing until every
   one is settled and nothing is in flight, and at that moment the close (§5.2) sets `closed_at`.
   An admin can also ask for a close, which is the backstop for a version that never settles.

And the fifth, which is retention's: **a season's standings are kept in the database and are
viewable forever** — `GET /v1/games/{game}/leaderboard?season=N` for any N, and the season list
beside it (§6.7, §7).

### 4.2 The four states

Derived from three timestamps; no status column, so nothing has to be kept in step:

```sql
CASE WHEN s.closed_at IS NOT NULL         THEN 'closed'       -- standings final (§4.6)
     WHEN now() < s.submissions_open_at   THEN 'scheduled'    -- created ahead; submissions refused
     WHEN now() < s.submissions_close_at  THEN 'open'         -- inside the window; play
     ELSE                                      'settling' END -- no submissions; play until settled
```

A *live* season is one whose `closed_at` is null — `scheduled`, `open` or `settling`. Pair, the
demand view and admission act on the live season; Soma's submission endpoint acts on an `open`
one; the close acts on a `settling` one (or any live one on request).

### 4.3 Scope — decision 23: per game

| | Option | Shape | Cost |
|---|---|---|---|
| **A** | **Per game** — chosen | `seasons (game_id, number)`; "Ants season 3" | the site says which game's season; two games close on different days |
| B | Global | one row for every game; each game's digest and dates in a join table | a join table for the facts a season exists to hold; and rule 4 — closing when settled — would mean every game waits for the slowest |

Everything a season holds is per game: its engine, its weight classes, its field, and
now its dates and its settling. The class thresholds and the opset are platform-wide and **not**
pinned by a season (admission §8 keeps them in code).

### 4.4 The engine digest: the deploy declares, the season pins

`games.active_engine_digest` **stays**, as what the deploy step declares current (finding 5 A;
`devops/compose/loader/run.sh` writes it today). A season **pins a copy** at creation:
`seasons.engine_digest` is what pair stamps on every row of the season and what withdraw's
`ENGINE_RETIRED` compares against. The two columns mean different things, and a difference between
them is a fact rather than a drift: *a rules change is waiting for the next season.*

| Reader | Reads |
|---|---|
| the create (§5.1) | `games.active_engine_digest`, copied onto the new season; refused when null |
| pair's insert (§6.1) | the live season's digest |
| withdraw's sweep (§6.5) | the row's season's digest → `ENGINE_RETIRED`; the row's season closed → `SEASON_CLOSED` |
| Kalam's claim (the schema §4.2) | **unchanged**: the row carries what it needs. Kalam is season-blind as it is roster-blind |
| the deploy step (§5.3) | writes `games` always; writes the live season's copy only for a patch, and refuses a release while a season is live |

### 4.5 The table, and the columns it adds

```sql
CREATE TABLE seasons (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id              uuid        NOT NULL REFERENCES games (id),
    number               int         NOT NULL,                        -- 1, 2, … per game

    -- Pinned from games.active_engine_digest at creation (§4.4). A behaviour-preserving patch
    -- updates it in place; a rules change waits for the next season.
    engine_digest        text        NOT NULL,

    submissions_open_at  timestamptz NOT NULL,                        -- rules 1 and 3: the window opens; the gap is checked here
    submissions_close_at timestamptz NOT NULL,                        -- rules 1 and 4: the window closes
    closed_at            timestamptz,                                 -- rule 4: set by the close, once

    -- The season's submission rules (§4.8): one document, each rule under its own key with an
    -- `enabled` flag, so a rule can be turned on or off per season without a schema change. The
    -- check refuses a key this schema does not know, which makes a typo a loud failure.
    rules                jsonb       NOT NULL DEFAULT '{}'::jsonb,

    -- An admin's request to close (§5.2). Consumed by the close on withdraw's next tick; stays
    -- set on the closed row as the record that it was asked for rather than reached.
    close_requested_at   timestamptz,

    -- The TinyBrain Index's λ, fitted and published per season (§13). Unread today.
    lambda               float8,

    created_at           timestamptz NOT NULL DEFAULT now(),

    UNIQUE (game_id, number),
    CONSTRAINT seasons_number_positive CHECK (number >= 1),
    CONSTRAINT seasons_window          CHECK (submissions_close_at > submissions_open_at),
    CONSTRAINT seasons_rules_known     CHECK (jsonb_typeof(rules) = 'object'
                                          AND (rules - 'unique_weights' - 'participants') = '{}'::jsonb)
);

-- Rule 3: at most one live season per game. This is the non-overlap rule, as an index.
CREATE UNIQUE INDEX seasons_one_live_uniq ON seasons (game_id) WHERE closed_at IS NULL;
```

On `models` and `matches`:

```sql
-- models: rule 2. Stamped by POST /v1/submissions from the live season; by the create for a
-- carried baseline; never changed.
    season_id       uuid         NOT NULL REFERENCES seasons (id),

-- the one-active rule becomes per season: a closed season's final version stays `active` -- it
-- IS the standing -- and the same owner has another in the next season
    CONSTRAINT models_one_active_excl
        EXCLUDE USING btree (owner_id WITH =, game_id WITH =, season_id WITH =)
        WHERE (status = 'active') DEFERRABLE INITIALLY DEFERRED,

-- (this index named `repo` and `release_tag`, both since deleted -- see admission.md §3.1.
--  `version` is the per-entry counter now, and `model_versions_model_version_uniq` is the key)

-- the class ladders, now by season
CREATE INDEX models_season_class_active_idx
    ON models (season_id, weight_class) WHERE status = 'active';

-- matches: stamped by pair from the live season, beside the digest it took from it. For the
-- archive, the sweep and the settle predicate; the claim never reads it.
    season_id            uuid         NOT NULL REFERENCES seasons (id),
```

Unchanged on purpose: `models_one_in_flight_uniq (owner_id, game_id)` — one submission in flight
per competitor per game, whichever season; since only one season is ever live, a season
qualifier would add nothing. `models_owner_game_version_uniq` — versions keep numbering across
seasons, so "alice v7" names one thing. `ratings`, `rating_events`, and the whole of Kalam's
grant.

**What is deliberately not here.** No status column (§4.2). No `season_id` on `ratings` or
`rating_events`: a version is of one season. No snapshot table for a closed season's standings:
the `active` versions of that season and their `ratings` rows *are* the standings.

### 4.6 What "settled" means — the close predicate

A live season closes by itself when, at some tick after its last submission date, all of the
following hold:

1. **every submission is decided** — no version of the season is `testing` or `verified`;
2. **nothing is in flight or waiting to be counted** — no match of the season is `pending`,
   `claimed`, `running` or `finished`;
3. **every active version is settled**, baselines included — on both ladders its sigma is at or
   below `settled_sigma` and its match count is at least `burst`, which is exactly the clocks §4's
   `settled` state. A baseline wants its own placement and steady matches like any version
   (decision 28), so it settles like one.

Together these say what the demand view says when it says zero: the ladder has nothing left to
learn, so nothing plays, so the standings will not move.

**"Settled" is judged on the ladders a version can reach — a correction to the clocks §4 that
building this found.** The demand view took `played` as the smaller of a version's two ladder
counts and `sigma` as the larger, so a version **alone in its weight class** — whose class ladder
no match can ever feed, because there is nobody of its class to play — was `placement` for ever:
its class count stayed at zero, its cap stayed at `burst`, and demand never fell. On the local
stack the one Micro version had played **4,430 counted matches** against the Nano baselines on
the `open` ladder, sigma 0.70, still wanting eight more, and its season could never have closed by
settling. Both the demand view and the close now count a class ladder only when **another active
version of the class is in the season**; a lone version is judged on `open` alone, and the moment
a second of its class arrives both go back to `placement` on the class ladder and play each other.
The rule is one `FILTER` on two aggregates and one lateral count, in `gen-clocks.py` for both
statements. The close is therefore the moment demand
reaches zero *after submissions closed* — before that, zero demand is a lull, not an end. A
version that never settles — one that faults on every match, say, so its sigma never falls —
holds the season open; that is what the admin's close request is for, and the build's `retired` status is
the longer answer.

### 4.7 The baselines are carried into each new season

Rule 2 puts every version in one season, baselines included, and a season with no baseline has no
trial opponent. Rather than an admin re-submitting three baselines each season, **the create
carries them**: for each active baseline version of the previous season it inserts a new `models`
row in the new season — the next version number for that owner, the same release, hashes,
manifest and `orion_version`, `active` at once — with its two rating rows at the prior and
their `seq = 0` events. The bytes are already in the store and were already verified; nothing is
fetched and nothing is re-admitted. An Orion upgrade between seasons is admission §9's
re-validation sweep, which reads `model_versions.manifest` and does not care which season a row is
in.

The first season of a game has no previous season to carry from; its baselines are placed as the
seed places them today (`seed.sql`), or submitted by an admin through the ordinary path. A
carried baseline is not a submission, so the season's rules (§4.8) do not apply to it. Once
carried it is an ordinary version of the season: paced, rated and settled like any other (§4.6).

### 4.8 The season's rules

A season may restrict what it accepts, and the restrictions differ from season to season — so
they are **content on the season row**, not code: `seasons.rules`, one document, each rule under
its own key, each with an `enabled` flag. A rule that is absent is off. Two rules exist to begin
with, and the owner's two examples are both of them:

```json
{
  "unique_weights": { "enabled": true, "scope": "game" },
  "participants":   { "enabled": true, "user_ids": ["<uuid>", "<uuid>"] }
}
```

| Rule | When enabled | Parameters | Why |
|---|---|---|---|
| **`unique_weights`** | a submission is refused when **another user** already holds a version with the same `weights_hash` — one that is `testing`, `verified`, `active` or `superseded`. A competitor may resubmit their own weights; a `rejected` row does not count, because the commonest rejection is `HASH_MISMATCH`, which means those bytes were never there | `scope`: `"game"` (default — any season of this game) or `"season"` (this season only) | "no two submissions can have the same digest from different users." The baselines are versions too, so under this rule nobody can enter a baseline's weights as their own |
| **`participants`** | only the listed users may submit | `user_ids`: the allowlist, as user ids — a handle can change, an id cannot. The admin endpoint accepts handles and resolves them at creation | "only selected users can participate." Enabled with an empty or missing list, nobody can |

Both are checked **in the submission insert itself** (§6.6), as predicates on the season row the
insert joins, so a rule is enforced by the statement that would violate it and not by a check
beside it. Soma tells the competitor which rule refused them. `seasons_rules_known` refuses a
document with a key this schema does not name, so a misspelt rule fails at creation rather than
silently never applying. A third rule is a key, a row in this table, and a predicate in one
statement.

---

## 5. The three statements

### 5.1 The create — Soma, `POST /v1/games/{game}/seasons`, admin only

`$1` game · `$2` `submissions_open_at` · `$3` `submissions_close_at` · `$4` `season_gap_days` · `$5`,
`$6` the prior `mu`, `sigma` · `$7` the rules document:

```sql
WITH game AS (
    SELECT g.id, g.active_engine_digest FROM games g WHERE g.id = ($1)::uuid
), last AS (
    SELECT max(number) AS number, max(closed_at) AS closed_at
      FROM seasons WHERE game_id = ($1)::uuid
), created AS (
    INSERT INTO seasons (game_id, number, engine_digest, submissions_open_at, submissions_close_at,
                         rules)
    SELECT game.id, coalesce(last.number, 0) + 1, game.active_engine_digest,
           ($2)::timestamptz, ($3)::timestamptz, coalesce(($7)::jsonb, '{}'::jsonb)
      FROM game, last
     WHERE game.active_engine_digest IS NOT NULL                                  -- an engine exists
       AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = game.id AND s.closed_at IS NULL)
       AND ($2)::timestamptz >= coalesce(last.closed_at, '-infinity'::timestamptz)
                                + make_interval(days => ($4)::int)                -- rule 3: the gap
 RETURNING id, number
), carried AS (
    INSERT INTO models (owner_id, game_id, season_id, version,
                        status, weight_class, size_bytes, param_count, infer_us,
                        weights_hash, manifest_hash, manifest, orion_version)
    SELECT b.owner_id, b.game_id, created.id,
           (SELECT max(x.version) FROM models x
             WHERE x.owner_id = b.owner_id AND x.game_id = b.game_id) + 1,
           'active',
           b.weight_class, b.size_bytes, b.param_count, b.infer_us,
           b.weights_hash, b.manifest_hash, b.manifest, b.orion_version
      FROM created
      JOIN seasons prev ON prev.game_id = ($1)::uuid AND prev.number = created.number - 1
      JOIN models b      ON b.season_id = prev.id AND b.status = 'active'
      JOIN users u       ON u.id = b.owner_id AND u.role = 'baseline'
 RETURNING id, weight_class
), seeded AS (
    INSERT INTO ratings (model_id, ladder, mu, sigma)
    SELECT c.id, l.ladder, ($5)::float8, ($6)::float8
      FROM carried c
      CROSS JOIN LATERAL (VALUES (c.weight_class), ('open'::ladder)) AS l (ladder)
 RETURNING model_id, ladder, mu, sigma
), events AS (
    INSERT INTO rating_events (model_id, ladder, seq, mu_after, sigma_after)
    SELECT model_id, ladder, 0, mu, sigma FROM seeded
 RETURNING model_id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM created WHERE c.key = 'roster'
```

`rows_affected` is one on success and **zero when refused**. It is a `db_write` whose last
statement is the roster bump rather than a read of what it made, because `db_write` reports only
`rows_affected` and a data-modifying CTE runs whether or not the outer statement uses it; Soma
then reads the live season back with the state read (§6.7) for the `201`, or, on zero, reads why
(§6.7) and answers `409` naming one of three reasons: a season of the game is still live, the
opening date is inside the gap (with the earliest allowed), or the game has no engine declared.
`number` is `last + 1` whether the last season ran or was cancelled unopened, so a cancelled
season consumes its number and the sequence stays honest. The roster epoch is bumped because a
new season with carried baselines is a roster change: a pair run mid-plan halts and re-reads.

The prior is the one `[vars]` value the routes and the clocks both read (§8); the seed's must equal it.

### 5.2 The close — `tb-withdraw-run`'s second task, and the admin's request

Withdraw's run was one idempotent statement (the clocks §7); it is now two, both idempotent, neither
fenced. The close is the tail of withdraw's run rather than a fifth clock for the reason admission
§9 made re-validation the tail of admission's: it fires rarely, needs no fence of its own, and a
channel nothing ships must not linger ticking. It runs once a minute with `$1` game · `$2`
`settled_sigma` · `$3` `burst`:

```sql
WITH live AS (
    SELECT s.id
      FROM seasons s
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL
       AND (s.close_requested_at IS NOT NULL                                     -- the admin asked
         OR (s.submissions_close_at <= now()                                     -- §4.6, all three
             AND NOT EXISTS (SELECT 1 FROM models md
                              WHERE md.season_id = s.id AND md.status IN ('testing', 'verified'))
             AND NOT EXISTS (SELECT 1 FROM matches m
                              WHERE m.season_id = s.id
                                AND m.status NOT IN ('rated', 'cancelled', 'failed'))
             AND NOT EXISTS (SELECT 1
                               FROM models md
                               LEFT JOIN ratings r ON r.model_id = md.id
                              WHERE md.season_id = s.id AND md.status = 'active'
                              GROUP BY md.id
                             HAVING count(r.model_id) = 0
                                 OR max(r.sigma) > ($2)::float8
                                 OR min(r.matches_played) < ($3)::int)))
), closed AS (
    UPDATE seasons s SET closed_at = now()
      FROM live WHERE s.id = live.id
 RETURNING s.id
), rejected AS (                                   -- only a requested close finds any
    UPDATE models md SET status = 'rejected', reject_reason = 'SEASON_CLOSED'
      FROM closed
     WHERE md.season_id = closed.id AND md.status IN ('testing', 'verified')
 RETURNING md.id
), withdrawn AS (                                  -- likewise; the sweep catches a straggler (§6.5)
    UPDATE matches m
       SET status = 'cancelled', withdrawn_reason = 'SEASON_CLOSED', closed_at = now()
      FROM closed
     WHERE m.season_id = closed.id AND m.status = 'pending'
 RETURNING m.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM closed WHERE c.key = 'roster'
```

`rows_affected` is one on a close and **zero almost every minute**, which is the normal case and
not a halt — withdraw's run has no fence to lose. A close reached by settling rejects nothing and
cancels nothing, because §4.6 says there is nothing to; a close the admin asked for rejects the
versions still waiting with the one reason that does not mean "your model is wrong", cancels the
queue, and leaves in-flight matches to finish and count into the season, where the standings
settle a few minutes later. Two runs overlapping cannot both close a season: the second's `UPDATE
… WHERE closed_at IS NULL` waits on the row lock, re-evaluates, and returns nothing.

**A close that wrote is told.** `notify_closed` follows it in the same run, only when `rows_affected`
was one: every competitor with a version in the season gets one `season` notification, keyed on the
season, naming where they finished on the open ladder by `model_ratings()`'s order, and linking
`/leaderboard?season=N`. It is `continue_on_error` and not part of this statement, so a notification
can never be the reason a season stays open. [`schema.md`](schema.md) §3.11.

**The admin's request** — Soma, `POST /v1/games/{game}/seasons/current/close`, admin only — is one
line, and it is an intent the close consumes within the minute rather than a copy of the close:

```sql
UPDATE seasons s SET close_requested_at = now()
 WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL AND s.close_requested_at IS NULL
```

A second request, like a request when no season is live, answers `409 no_live_season`. A
`scheduled` season closed on request is a cancelled season: it never opened, it carried its
baselines for nothing, and its number is consumed.

### 5.3 The deploy step's two statements — deployment

Both one statement; `$1` game · `$2` digest. **Patch** — the new engine is behaviour-preserving,
so the live season keeps its ratings and takes the new digest:

```sql
WITH g AS (
    UPDATE games SET active_engine_digest = ($2)::text
     WHERE id = ($1)::uuid AND active_engine_digest IS DISTINCT FROM ($2)::text
 RETURNING id
), s AS (
    UPDATE seasons s SET engine_digest = ($2)::text
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL AND s.engine_digest <> ($2)::text
 RETURNING s.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM s WHERE c.key = 'roster'
```

Withdraw's sweep then cancels every `pending` row still naming the old digest as
`ENGINE_RETIRED` within the minute, and pair re-inserts on the new one. This is what
`devops/compose/loader/run.sh` does on every `up` today, plus the season's copy.

**Release** — the new engine changes the rules, so it may not enter a live season:

```sql
UPDATE games g SET active_engine_digest = ($2)::text
 WHERE g.id = ($1)::uuid
   AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = g.id AND s.closed_at IS NULL)
```

Zero rows means a season is live and **the loader must fail loudly** — the replicas carrying the
new engine claim nothing, because every row of the season names the old digest, and a season that
silently stops playing is the worst outcome. The operator's choices are to roll back, or to ask
the admin to close the season; the next season pins the new digest at creation. `ENGINE_RELEASE=1`
selects this statement; the default is the patch, as today.

---

## 6. The statements a season touches

### 6.1 Pair's fenced insert — the schema §6.2

The live season supplies the digest and is what every seat must belong to:

```sql
WITH season AS (
    SELECT s.id, s.game_id, s.engine_digest
      FROM seasons s
      JOIN games g ON g.id = s.game_id AND g.slug = ($2)::text
     WHERE s.closed_at IS NULL
), seated AS MATERIALIZED (
    SELECT seat.ord - 1 AS seat, md.id AS model_id, md.weights_hash, md.manifest_hash, md.weight_class
      FROM unnest(($5)::uuid[]) WITH ORDINALITY AS seat (model_id, ord)
      JOIN models md ON md.id = seat.model_id
      JOIN season    ON season.id = md.season_id                        -- of the live season
     WHERE md.status = 'active'
        OR (md.status = 'verified' AND md.id = ($6)::uuid)
), m AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders,
                         trial_model_id, pairing_id)
    SELECT season.game_id, season.id, season.engine_digest, ($3)::bigint, ($4)::text,
           cardinality(($5)::uuid[]),
           CASE WHEN ($6)::uuid IS NOT NULL THEN '{}'::ladder[]
                WHEN (SELECT count(DISTINCT weight_class) FROM seated) = 1
                     THEN ARRAY[(SELECT weight_class FROM seated LIMIT 1), 'open']::ladder[]
                ELSE ARRAY['open']::ladder[]
           END,
           ($6)::uuid, ($7)::uuid
      FROM season
      JOIN (SELECT key FROM clocks WHERE key = 'roster' AND epoch = ($1)::bigint FOR SHARE) fence
        ON true
     WHERE (SELECT count(*) FROM seated) = cardinality(($5)::uuid[])
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, model_id, weights_hash, manifest_hash, paired_ratings)
SELECT m.id, s.seat, s.model_id, s.weights_hash, s.manifest_hash,
       (SELECT jsonb_agg(jsonb_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma)
                         ORDER BY r.ladder)
          FROM ratings r WHERE r.model_id = s.model_id)
  FROM m, seated s
```

No live season, or a seat from another season, and the statement inserts nothing; pair halts
and the next run re-reads, exactly as a null digest paused it before.

### 6.2 The trial insert — the clocks §6.4

One line: the baseline must be of the candidate's season —
`WHERE b.game_id = c.game_id AND b.season_id = c.season_id AND b.status = 'active'`. A candidate is
only ever `verified` in the live season, so this is what makes the carried baseline, not last
season's, its opponent.

### 6.3 The demand view — the clocks §4

One join. `v` reads the live season's versions:

```sql
WITH live AS (
    SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL
), v AS (
    SELECT md.id AS model_id, md.weight_class,
           max(r.sigma) AS sigma, min(r.matches_played) AS played
      FROM models md
      JOIN live   ON live.id = md.season_id
      LEFT JOIN ratings r ON r.model_id = md.id
     WHERE md.status = 'active'
     GROUP BY md.id, md.weight_class
), …
```

The rest is as written. A `scheduled` season has only its carried baselines, back at the prior, so
they play their placement against each other before the first submission is promoted; a closed
season is not read at all.

### 6.4 Promotion's pass — the schema §5.3

Two changes. The predecessor is the owner's active version **in the candidate's season**, and the
mark is guarded on that season being live, upstream of every write:

```sql
), live AS (
    SELECT s.id
      FROM seasons s JOIN models c ON c.season_id = s.id
     WHERE c.id = ($4)::uuid AND s.closed_at IS NULL
), mark AS (
    UPDATE matches m
       SET status = 'rated', rated_at = now(), rated_seq = nextval('rating_seq')
      FROM fence, live
     WHERE m.id = ($3)::uuid AND m.status = 'finished' AND m.trial_model_id = ($4)::uuid
 RETURNING m.id
), …
), pred AS (
    UPDATE models p SET status = 'superseded'
      FROM bump, models cand
     WHERE cand.id = ($4)::uuid
       AND p.owner_id = cand.owner_id AND p.game_id = cand.game_id
       AND p.season_id = cand.season_id AND p.status = 'active'
 RETURNING p.id
), …
```

A data-modifying CTE runs to completion whether or not the outer statement uses it, so the guard
has to sit on the mark — the same reason the schema §5.2's length guard does. In practice the guard is
never reached: a close on request rejects a waiting candidate in the same statement, and a close
by settling finds none. The seed CTE and the events are the schema's, unchanged.

### 6.5 Withdraw's sweep — the schema §7.1

The row's season is joined; a closed season is a reason, tested first:

```sql
UPDATE matches m
   SET status = 'cancelled', closed_at = now(),
       withdrawn_reason =
           CASE WHEN s.closed_at IS NOT NULL            THEN 'SEASON_CLOSED'
                WHEN m.engine_digest <> s.engine_digest THEN 'ENGINE_RETIRED'
                ELSE (SELECT CASE md.status WHEN 'superseded' THEN 'SUPERSEDED'
                                            WHEN 'rejected'   THEN 'REJECTED'
                                            ELSE 'SEAT_LEFT' END
                        FROM match_seats st
                        JOIN models md ON md.id = st.model_id
                       WHERE st.match_id = m.id
                         AND NOT (md.status = 'active'
                               OR (md.status = 'verified' AND md.id = m.trial_model_id))
                       ORDER BY st.seat LIMIT 1)
           END,
       successor_id =
           (SELECT succ.id
              FROM match_seats st
              JOIN models gone ON gone.id = st.model_id AND gone.status = 'superseded'
              JOIN models succ ON succ.owner_id = gone.owner_id AND succ.game_id = gone.game_id
                              AND succ.season_id = gone.season_id AND succ.status = 'active'
             WHERE st.match_id = m.id
             ORDER BY st.seat LIMIT 1)
  FROM seasons s
 WHERE s.id = m.season_id AND m.status = 'pending'
   AND (s.closed_at IS NOT NULL
     OR m.engine_digest <> s.engine_digest
     OR EXISTS (SELECT 1 FROM match_seats st
                  JOIN models md ON md.id = st.model_id
                 WHERE st.match_id = m.id
                   AND NOT (md.status = 'active'
                         OR (md.status = 'verified' AND md.id = m.trial_model_id))))
```

`SEASON_CLOSED` here is the crash case only — the close cancels its own queue (§5.2) — and the
successor is looked up within the season, so a superseded version's successor is never one from
another season.

### 6.6 Soma's submission — `POST /v1/submissions`

The insert joins the game's **open** season, stamps it, and carries the season's rules as
predicates; the session join is as today:

```sql
INSERT INTO models (owner_id, game_id, season_id, version,
                    weights_hash, manifest_hash)
SELECT ($1)::uuid, g.id, s.id, coalesce(max(m.version), 0) + 1,
       ($6)::text, ($7)::text
  FROM games g
  JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL
               AND s.submissions_open_at <= now() AND now() < s.submissions_close_at
  JOIN live_sessions ls ON ls.sid = ($5)::uuid AND ls.user_id = ($1)::uuid
  LEFT JOIN models m ON m.owner_id = ($1)::uuid AND m.game_id = g.id
 WHERE g.slug = ($2)::text
   -- participants: when enabled, only the listed users
   AND (NOT coalesce((s.rules -> 'participants' ->> 'enabled')::bool, false)
        OR ($1)::text IN (SELECT jsonb_array_elements_text(s.rules -> 'participants' -> 'user_ids')))
   -- unique_weights: when enabled, no other user holds these weights
   AND (NOT coalesce((s.rules -> 'unique_weights' ->> 'enabled')::bool, false)
        OR NOT EXISTS (SELECT 1 FROM models o
                        WHERE o.game_id = g.id AND o.weights_hash = ($6)::text
                          AND o.owner_id <> ($1)::uuid AND o.status <> 'rejected'
                          AND (coalesce(s.rules -> 'unique_weights' ->> 'scope', 'game') = 'game'
                               OR o.season_id = s.id)))
 GROUP BY g.id, s.id
```

Zero rows and Soma reads why — the state read of §6.7 extended with the two rule verdicts for
this user and these weights — and answers `409` with one word: `season_not_open` (with the
season's number, state and dates, or `season: null` when the game has none), `not_a_participant`,
or `weights_already_entered`. The one-in-flight index and the per-season release index are what
refuse a duplicate, as today. The read-back that shapes the `201` is scoped to the live season,
so a release entered last season cannot be reported as this season's.

### 6.7 What Soma reads — the state, the list, the leaderboard

**The state**, for `GET /v1/games` (the current season of each game) and for every refusal:

```sql
SELECT s.number,
       CASE WHEN s.closed_at IS NOT NULL        THEN 'closed'
            WHEN now() < s.submissions_open_at  THEN 'scheduled'
            WHEN now() < s.submissions_close_at THEN 'open'
            ELSE                                     'settling' END AS state,
       s.submissions_open_at, s.submissions_close_at, s.closed_at, s.engine_digest, s.rules
  FROM seasons s JOIN games g ON g.id = s.game_id
 WHERE g.slug = ($1)::text
 ORDER BY (s.closed_at IS NULL) DESC, s.number DESC
 LIMIT 1
```

**Why a submission was refused** — the same row for the live season, with the two rule verdicts
for `$2` the user and `$3` the declared weights hash; `season` is null when the game has no live
season, and each verdict is true when its rule is off or satisfied:

```sql
SELECT json_build_object(
         'season', s.number,
         'state', CASE WHEN s.id IS NULL THEN NULL
                       WHEN now() < s.submissions_open_at  THEN 'scheduled'
                       WHEN now() < s.submissions_close_at THEN 'open'
                       ELSE                                     'settling' END,
         'submissions_open_at', s.submissions_open_at,
         'submissions_close_at', s.submissions_close_at,
         'participant',
           s.id IS NULL
           OR NOT coalesce((s.rules -> 'participants' ->> 'enabled')::bool, false)
           OR ($2)::text IN (SELECT jsonb_array_elements_text(s.rules -> 'participants' -> 'user_ids')),
         'unique_weights',
           s.id IS NULL
           OR NOT coalesce((s.rules -> 'unique_weights' ->> 'enabled')::bool, false)
           OR NOT EXISTS (SELECT 1 FROM models o
                           WHERE o.game_id = g.id AND o.weights_hash = ($3)::text
                             AND o.owner_id <> ($2)::uuid AND o.status <> 'rejected'
                             AND (coalesce(s.rules -> 'unique_weights' ->> 'scope', 'game') = 'game'
                                  OR o.season_id = s.id))) AS body
  FROM games g
  LEFT JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL
 WHERE g.slug = ($1)::text
```

— the live season if there is one, else the latest closed. **The list**,
`GET /v1/games/{game}/seasons`, is the same row for every season in `number` order; it is the
UI's index of past seasons. **The leaderboard**, `?season=N` or the current by default:

```sql
WITH season AS (
    SELECT s.id, s.number, (s.closed_at IS NOT NULL) AS closed
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = ($1)::text
       AND (($6)::int IS NULL OR s.number = ($6)::int)
     ORDER BY (s.closed_at IS NULL) DESC, s.number DESC
     LIMIT 1
), page AS (
    SELECT row_number() OVER (ORDER BY r.conservative DESC, m.id) AS rank,
           m.id::text AS model_id, u.handle AS owner, m.version,
           m.weight_class::text AS class, m.size_bytes,
           r.conservative AS rating, (r.sigma > ($5)::float8) AS provisional,
           r.matches_played AS matches
      FROM season
      JOIN models m  ON m.season_id = season.id AND m.status = 'active'
      JOIN ratings r ON r.model_id = m.id AND r.ladder = ($2)::ladder
      JOIN users u   ON u.id = m.owner_id
     WHERE (($2)::text = 'open' OR m.weight_class = ($2)::ladder)
     ORDER BY r.conservative DESC, m.id
    OFFSET ($4)::int LIMIT ($3)::int
)
SELECT json_build_object(
         'season', (SELECT number FROM season), 'closed', (SELECT closed FROM season),
         'entries', coalesce(json_agg(page ORDER BY page.rank), '[]'::json),
         'next_cursor', CASE WHEN count(*) = ($3)::int
                             THEN (($4)::int + ($3)::int)::text ELSE NULL END) AS body
  FROM page
```

The same predicate — `m.status = 'active'` of the season — serves an open season and a closed
one, because a closed season's `active` versions are its final standing: nothing supersedes them
after the close. The match object and the model read gain `season`; the model read's ratings
join is unchanged.

---

## 7. Retention — decision 24

**Retention is a policy table and one lifecycle rule, and nothing to build in the build.** Rule 5 —
standings kept forever — is the first row.

| What | Grows by | Kept | Bounded by |
|---|---|---|---|
| `models`, `ratings`, `rating_events` — a season's standings and their history | one version, two rating rows, and seats × ladders events per counted match | **forever** | nothing, on purpose. The standings page of any past season is a read (§6.7); the events are the audit and the recompute |
| `matches` and `match_seats` | one row plus one per seat, per match; ~1 KB | **indefinitely**, this draft | nothing yet. `season_id` is what makes a per-season archive one `DELETE … WHERE season_id = …` when a closed season's match rows are worth more than the disk; the standings survive it |
| replays in the object store | one envelope per attempt, ~4.7 KB for Ants; a replayed wave leaves the stale attempt's blob as an orphan | `replay_ttl_days` from the write | **the bucket's lifecycle rule** — R2 and minio both expire objects by age. No clock; orphans expire under the same rule; the Replay screen says "replay expired" |
| the model store: weights and adapters by hash | S per admitted version, mirrored at admission | while any version naming the hash is `testing`, `verified` or `active` **in a live season**, or has a match in flight | a sweep over the store against the query below — **deferred**: a Micro is 64 KiB; a Large is 64 MiB and there are none yet |
| Orion traces | one record per occurrence; `errors_only` on the wave channel | Orion's own retention | deployment's `[tracing]` config |

The evictable hashes, for the day the store sweep exists — a closed season's versions are
evictable, since nothing will ever play them again:

```sql
SELECT DISTINCT h.hash
  FROM (SELECT weights_hash AS hash FROM models
        UNION SELECT manifest_hash FROM models) h
 WHERE h.hash IS NOT NULL
   AND NOT EXISTS (
       SELECT 1
         FROM models md
         JOIN seasons s ON s.id = md.season_id
        WHERE (md.weights_hash = h.hash OR md.manifest_hash = h.hash)
          AND ((s.closed_at IS NULL AND md.status IN ('testing', 'verified', 'active'))
            OR EXISTS (SELECT 1 FROM match_seats st JOIN matches m ON m.id = st.match_id
                        WHERE st.model_id = md.id
                          AND m.status IN ('pending', 'claimed', 'running'))))
```

**Ratings stay recomputable after archival** by construction: `rating_events` records every
event's `before` and `after`, so a season's ratings can be replayed from its events with no match
row present, and the chain constraint proves the replay complete.

**The two numbers.** At the local stack's rate — one replica, 2,334 counted matches in a day — a
year is ~850,000 matches, ~4 GB of replays and ~2.5 GB of rows; at ten replicas, ten times that.
Neither needs a decision before the first season closes.

---

## 8. The numbers

Every rating number, what moves it, and — now that the ladder runs — **the query that measures
it**, are in [`config.md`](config.md) §3 and §5. The headline finding belongs here too: on a field
of five hand-placed fixtures, **99.8% of counted matches were draws**, which makes
`ts_draw_probability = 0.10` a value for a field that plays rather than one that idles.

---

## 9. What this page asks of its neighbours

- **The schema / `0001_init.sql`** — §11: the `seasons` table, `season_id` on `models` and
  `matches`, the two constraints re-scoped, the class index by season, season 1 in the seed.
- **The clocks** — the four statements of §6.1 to §6.5 in `scripts/gen-clocks.py`, checked by
  `check-sql.sh`; the close as withdraw's second task, reading `settled_sigma` and `burst`. And
  one ask of `tb.pairing`, **recommended and not decided**: spend one match of a placement burst
  on the current leader of the version's class ladder — the king match — as the pairing-side
  answer to §3's stale top. It costs one of `burst` and no schema; it is the clocks's call because
  it changes what a burst measures.
- **Soma** — three endpoints: `POST /v1/games/{game}/seasons` and
  `POST /v1/games/{game}/seasons/current/close`, both admin only — `users.role = 'admin'` exists
  and nothing reads it yet — and `GET /v1/games/{game}/seasons`; the create takes the window and the rules document, and
  resolves participant handles to ids; the submission insert of §6.6 with its four refusals; the leaderboard's `?season=`; the current season on `GET /v1/games`;
  `season` on the match object and the model read; `season_gap_days`, `prior_mu` and
  `prior_sigma` in Soma's `[vars]`. If Orion's `db_read` refuses a data-modifying CTE, the create
  is a `db_write` followed by a read of the one live season, whose number is `last + 1` either
  way.
- **`devops/`** — the loader's digest write becomes §5.3's patch, with
  `ENGINE_RELEASE=1` selecting the release, **which fails loudly while a season is live**; the
  replay bucket's lifecycle rule at `replay_ttl_days`; the autoscaler must expect demand to fall
  to zero as a season settles and to jump when the next one's first versions are promoted.
- **The web track** — the admin screen: create a season with its two dates, request a close; the
  season on the leaderboard's header, the state and the dates on the game page, past seasons by
  number; the three submission refusals as words; "replay expired" on the Replay screen.
- **Kalam and `ants`** — nothing. The row carries the digest; neither the plugin nor the match clock
  ever hears the word season.
- **The risk register** — "a settled version stops being selected" is answered by pairing's king
  match, and bounded by the season.

---

## 10. Decisions taken here

Decisions **11** (sigma inflation at seed), **12** (rank ties), **23** (season scope is per game)
and **24** (retention as a policy table), together with the unnumbered calls — `tau` per update and
no clock that inflates a sigma, what a season is, one season per version stamped at submission,
non-overlap by partial unique index, withdraw as the closer, where the engine digest lives,
baselines carried into each new season, and the season's rules as a document on the row — are
recorded with their reasoning and the cost of flipping each in
[decisions.md](decisions.md) §3,
under *The clocks*.

---

## 11. What the schema gains

In initial-schema form, as `0001_init.sql` is rewritten: nothing is released, so there is no
`ALTER` and no `0003`. `seasons` is created after `games` and before `models`; §4.5 has the
table and the columns. Unchanged: `games` (the digest stays), `ratings`, `rating_events`,
`match_seats`, `clocks`, and the Kalam role's grants — Kalam reads no season and writes no column
that names one, and [scripts/verify/run.sh](../scripts/verify/run.sh) asserts that too.

**The seed** — `devops/compose/bootstrap/seed.sql`: season 1 for `ants`, opening now, submissions
closing a year out (a dev stack's season is long), pinning the placeholder digest the loader's
patch overwrites on the first `up`; the three baselines' `models` rows carry its id, and their
ratings and `seq = 0` events are as today.

**The withdrawn-reason vocabulary** gains `SEASON_CLOSED`; **the rejection vocabulary** (admission §7)
gains `SEASON_CLOSED` too — the one word in it that does not mean "your model is wrong", beside
`TIMED_OUT`.

---

## 12. What is verified, and what is not

**Verified on Postgres 16**, 8 September 2026, in the local compose stack: the shipped
`0001_init.sql`, every statement in §5 and §6 `PREPARE`d, and a walk that **asserted** each step
below. The shared statements are kept current in
[scripts/verify/](../scripts/verify/), which runs
the same shape against every one of them; what this package actually ships is re-checked by
[`scripts/check-sql.sh`](../scripts/check-sql.sh) on every change. The steps that held:

1. a submission into an open season is stamped with it and numbered; its trial is paired in the
   season on the season's digest;
2. the pass promotes it at the prior in season 1; a ranked match folds into the schema's unchanged
   `ratings` rows;
3. the close: with submissions still open, nothing; with them closed but the version unsettled,
   nothing; settled, the season closes, the epoch bumps, and a submission is refused; the state
   read says `closed`;
4. the create: an opening date inside the gap is refused; outside it, season 2 is created as
   `scheduled` with the game's digest, the baseline carried as a new active version at the prior
   with its `seq = 0` events, and the epoch bumped; a second create while one is live is refused;
   a submission into a `scheduled` season is refused; opened, the same release as season 1 is
   accepted; the trial insert seats the carried baseline and not last season's; pairing a
   last-season seat inserts nothing; the promotion leaves both seasons' versions `active` under
   the per-season one-active rule;
5. the leaderboard reads the live season by default and season 1 by number;
6. a release is refused while a season is live; a patch updates the game and the live season
   and bumps the epoch, and the sweep retires the old-digest row; a patch to the same digest is
   zero rows;
7. an admin's close request closes a season with a candidate waiting and a row queued: the
   candidate is rejected `SEASON_CLOSED`, the row cancelled `SEASON_CLOSED`, the epoch bumped;
   the release then succeeds;
8. the pass with the candidate's season closed by hand touches nothing — not the trial, the
   roster, or the models; reopened, it promotes;
9. a `pending` row on a closed season is swept `SEASON_CLOSED`;
10. the rules: with `participants` enabled and a list, an unlisted user is refused and the
    refusal read names it; a listed user is accepted; with `unique_weights` enabled, a second
    user submitting a first user's weights is refused and the read names it, the first user
    resubmitting their own is not, and weights held only by a `rejected` row do not count; with
    scope `season`, weights from a previous season are accepted; a rules document with an unknown
    key is refused by the schema;
11. the draw-fraction query over season 1; the evictable-hash query names the closed seasons'
    hashes and none carried into the live season; the chain audit finds no break; the Kalam role
    can neither write `matches.season_id` nor read `seasons`.

**Verified on Orion**, 8 September 2026, on the local stack, after the build: the close as
withdraw's second task, both by settling and on request, with a `db_write` of zero rows every other
minute and no halt; the create, the close request, the seasons list, the current season on the game
read, the leaderboard by season; the submission insert refusing `season_not_open` and
`not_a_participant` and accepting a listed user; pair's insert, the trial insert and count's pass
scoped to the live season, on a real trial and burst. The create is a `db_write` whose last
statement is the roster bump, so whether `db_read` accepts a data-modifying CTE was never needed.

**Not verified**: the `unique_weights` refusal end to end over HTTP — proven by the harness, and
the same predicate as the participant one, but not driven; the demand spike after a season opens
against a real autoscaler (deployment); and every number in §8 against a field that plays.

---

## 13. Ranking beyond a ladder — designed, not built

Everything above is what runs. This section is the ranking design that has **no implementation
yet**, kept here because it is the reason the two-ladder rule is shaped the way it is.

**Which ladder a match counts for is derived, never declared.** An all-Micro match feeds Micro *and*
Open; a mixed-size match feeds Open only. That dissolves an ambiguity a declared ladder would
create — is an all-Micro match a Micro match, or an Open one that happened to draw two Micros? Both.
It also stops class matches being wasted on the ladder that most needs data.

The obligation this moves onto pairing: **Open is only meaningful if cross-class matches actually
get scheduled.** All-same-class play would leave Open a set of disconnected TrueSkill graphs, where
a Nano rating and a Large rating are not on a comparable scale. `cross_class_fraction` is that
policy value, and it is not an accident.

**The Pareto frontier.** Rating against log size, read off the Open ladder — the only ladder where a
Nano and a Small have actually met. A model is *frontier-dominant* if nothing smaller beats it.
This is the real headline of the competition and is intended to be the leaderboard's primary
visual.

**The TinyBrain Index**, for a single sortable number:

```text
index = rating − λ · log₂(size / 1 KiB)
```

`λ` is fitted per season and published. It is **decision 30, still open**: fit it after season one,
or publish a provisional value so competitors have something to optimise against from day one. The
`seasons` table already carries a nullable `lambda` column, unread, so that taking the decision
costs no migration.

**Across games there is no model ladder.** Model weights are not portable between cartridges,
because ABIs differ. What is possible is a **competitor all-around**: a decathlon score over a
person's best result in each game. A universal cross-game observation format is a tempting idea and
a bad one — it would compromise every game's ABI to serve a leaderboard.

**Anti-gaming**, for the record: random pairing defeats opponent-specific exploits; fresh world
seeds defeat memorised lookup tables; quotas and the one-in-flight rule defeat ladder spam; and
rating-anomaly detection would flag collusion. Only the first three exist.

---

## 14. Open questions

1. **Pairing's king match** (§9) — recommended to the clocks, not decided here.
2. **Scheduling ahead.** Rule 3 as taken means the next season is created after the previous
   closes, so there is always at least `season_gap_days` with no open season and nobody can
   announce "season 4 opens on the first" while season 3 settles. If that matters, the
   alternative is in §10: create ahead, and a clock pushes the opening back if the previous
   settles late.
3. **A version that never settles** holds its season open (§4.6). The admin's close is the
   backstop; whether count should retire a version after N consecutive faults is the build's `retired`.
4. **Whether `lambda` belongs here at all** — kept as one nullable column; the build decides.
5. **`unique_weights` and rejected rows.** A rejection for a trial forfeit *did* prove the bytes
   were there, and the rule still lets another user enter them afterwards. Counting rejections
   by reason is one predicate more if that ever matters.
