# Season maps, and season names

> **Draft 4, 19 September 2026 — AGREED AND BUILT the same day, as decision N28** (`decisions.md`). What
> each repository's share turned up is in its README's Status block. This replaces draft 1, *Map packages*,
> which is dropped. The user's six calls on that draft (§0) removed packages altogether. Four
> answers on draft 2 (§0b) settled visibility, the basic boards and what happens to a map that is
> taken out of play. Three on draft 3 (§0c) settled that an upload starts disabled, how season maps
> are backed up, and that season 1's boards leave the unpushed commits. Two
> changes to the season definition remain, designed together because both rewrite the `seasons` row:
> **an admin manages a season's maps directly, and may change them while the season is live**, and
> **a season has a name, and its slug is how it is addressed everywhere**. The decision this asks
> for is **N28**, the next free number (N26 was never used). §13 lists what is still open.

---

## 0. The user's calls, and what each means here

| # | Call | What it means in this design |
|---|---|---|
| 1 | Maps come in only by upload. Keep five basic maps for ants-starter testing. No season maps in commits or releases | An admin route is the only way a season map reaches the platform. No image, release or `bootstrap` carries one. Ants keeps five **basic** boards. They are not season maps: they ship in the release for the starter, the CLI, the engine's tests and admission's reference set (§3) |
| 2 | Remove presets | The word and the concept are removed from the engine's input, `cartridge.json`, `[vars]`, `rules`, `matches`, the pairing plugin, the claim, the replay envelope, the CLI's match file, web and the book |
| 3 | No packages. List, add and remove maps in the season's admin settings, and allow changes while the season is live | A `season_maps` table. Pairing reads the season's **enabled** maps on every run. A match already queued keeps the board it was paired on. "Remove" became **disable** (§0b.3) |
| 4 | Slug everywhere | `seasons.slug`, derived from the name at creation, is the season's key in every URL, route parameter, query, link and notification |
| 5 | No renaming | The name and the slug are fixed when the season is created |
| 6 | Season maps outside releases, in the root folder for now; forget package names; in prod they are uploaded when a season is created | Season 1's 32 boards and their recipes move to `tinybrains/maps/`, which is not a repository. The admin page uploads them into the season it creates |

### 0b. The answers on draft 2

| # | Answer | What it means in this design |
|---|---|---|
| 1 | Maps are public as soon as they are uploaded | Every map, board included, is readable by anyone from the moment its upload succeeds, disabled ones too. The season page can draw each one (§8) |
| 2 | One basic map per size | Five basic boards, one for each of tiny, small, medium, large and xlarge. Their seat counts span 2 to 8, because they define the upload limits (§3) |
| 3 | A map can only be disabled after upload, never removed | There is no delete. A map is **enabled** or **disabled**, and disabling can be undone. The row, its board and its matches stay for ever |
| 4 | Matches already running on a disabled map count | Disabling cancels only the `pending` matches on that map. Claimed and running ones finish and are counted |

### 0c. The answers on draft 3

| # | Answer | What it means in this design |
|---|---|---|
| 1 | A map can be disabled and enabled again. **A new upload is disabled until an admin enables it** | `season_maps.enabled` defaults to **false**. An upload changes nothing about pairing; enabling does. Enabling re-runs the engine check, because an engine patch may have landed since the upload (§6.2) |
| 2 | Season maps are managed outside the repositories, and **pushed to a repository as a backup after the season completes** | While a season runs, its maps exist in `tinybrains/maps/` and in Soma's database (every uploaded board is a `season_maps` row), and nowhere else. After the close, that season's maps and recipes are pushed to a backup repository. Never to ants, and never into a release (§3) |
| 3 | Keep season 1's boards out of the repositories, the releases and the commits | Step 0 is decided: the unpushed commits of §3 are rewritten before anything is pushed |

---

## 1. What is true today

A board reaches a match in six steps, and a season can only narrow the fourth:

1. `mapgen` renders `ants/mapgen/recipes/*.toml` into `ants/maps/*.json` (32 boards, one board per preset).
2. `ants/engine/build.rs` compiles every board into the component, so **a board is part of the engine digest**.
3. `cartridge.json` publishes `presets` and `maps`, and `bootstrap` stores them in `games.manifest`.
4. The deploy's `[vars].presets` (`docker/soma.toml.tmpl:80`) lists what pair may use. A season's `rules.pairing.presets` may name a subset (`0001_init.sql:185`).
5. Pair picks a preset and writes `matches.preset` (`gen-clocks.py` `P_TRIALS`/`P_INSERT`, `tb-pairing/src/choose.rs`).
6. The runner calls `worldgen(seeds, preset, players)` (`kalam/scripts/gen-kalam.py:638`), and the engine picks the board from that preset's pool by seed (`ants/engine/src/maps.rs:452`).

Admission validates every adapter against `games.reference_observations`, an early and a busy turn on
every preset in the catalogue (`ants/engine/src/bin/reference.rs`). A season has a `number` and no
name. Its number is the key in `/seasons/{number}`, `?season=N`, `current_season(game, number)` and
`notifications.season` (an `int`, `0002_sessions.sql:197`).

**`worldgen` already accepts a whole board as an object and validates it before playing it**
(`maps.rs` `resolve`, the third form). The platform has never used that form. This design uses
nothing else.

---

## 2. What a map is to the platform

**A map is one JSON file, the one `mapgen` writes.** Soma reads its **header**: `id`, `players`,
`rows`, `cols`. Everything else in the file is the **board**, which only the cartridge reads. Soma
stores it and passes it to `worldgen` untouched. This is the line the platform already draws around
`wave_state`.

**The engine judges whether a map is valid, at upload.** Soma loads the Ants component as a plugin
(its image already downloads the release that contains it). The upload calls
`tb.ants.worldgen({seeds: [0], map: <board>, players, max_turns: 1})`, and a fault is returned to
the admin in the engine's own words (`MAP_BAD_SHAPE`, `PLAYER_COUNT`, the symmetry and hill
refusals). A board that cannot be played never reaches pairing. Without this check, a bad board
would fail every match paired on it, one at a time, on runners.

**The envelope: what a season map may be.** Maps can change during a live season, so a model
admitted today must be able to play a board added next week. Admission therefore cannot test only
the maps the season has now. **It tests the whole range the game allows**, and an upload must fall
inside that range. The cartridge declares the range, derived from the five basic boards that the
reference set is generated from (§3):

```json
"limits": { "turn_ms": 1000, "max_turns": 1000,
            "boards": { "players": [2, 8], "sides": [24, 125] } }
```

An upload outside that range is refused as `map_outside_limits`, and the refusal names the bound.
That range is also the only thing a competitor has to design for: the book's `probe_dims` advice
becomes *"the largest board the game allows"*, not *"the largest preset the season runs"*. Kalam's
`MAX_SEATS` must be at least `players[1]`, and web's `configs.sh` checks that.

---

## 3. Where maps live

| Maps | Where | Committed | In the release | Used by |
|---|---|---|---|---|
| **The five basic boards** | `ants/maps/` (with their recipes in `ants/mapgen/recipes/`) | yes | yes, `dist/maps/` | the engine's tests; the reference set (and so the envelope); the starter's match files; `tinybrains env` and `maps export`; the book's lessons |
| **Season maps** | `tinybrains/maps/` (boards), `tinybrains/maps/recipes/` (their designs) | **not while the season runs**; pushed to a backup repository after it closes (§0c.2) | **never** | uploaded by an admin into a season |

**A season map's life:** designed with `mapgen` into `tinybrains/maps/`; checked with
`tinybrains maps check`; uploaded into the season (disabled); enabled by an admin; played; and,
once the season has closed, pushed with its recipe to a backup repository. It is never pushed to
ants and never shipped in a release. Until the push, the only copies are that folder and Soma's
database, which holds the board (never the recipe) and is covered by whatever backs the database
up.

**One basic board per size, and together they must span the envelope**, because they define it:
two seats to eight, and the smallest to the largest side a season may use. They are new designs,
not season 1 boards:

| Board | Size class (longer side) | Seats | Why this seat count |
|---|---|---|---|
| `basic-tiny-2p` | tiny, 24 a side (the envelope's smallest) | 2 | the duel, and the smallest board an adapter must handle |
| `basic-small-3p` | small (≤ 48) | 3 | an odd seat count, so no board symmetry that needs an even count can be assumed |
| `basic-medium-4p` | medium (≤ 64) | 4 | |
| `basic-large-6p` | large (≤ 96) | 6 | |
| `basic-xlarge-8p` | xlarge, 125 a side (the envelope's largest) | 8 | the most seats on the largest board: every owner number 0–7, and the adapter's worst case for its ops budget |

The reference set takes several seeds and turns on each board, to stay near today's 64
observations.

**`mapgen` keeps its default paths for the basic boards** and gains `--recipes DIR --out DIR` for
the season folder:

```sh
cd ants/mapgen
cargo run -- generate                                              # the five basic boards
cargo run -- generate --recipes ../../maps/recipes --out ../../maps  # season maps, in the root folder
cargo run -- check    --recipes ../../maps/recipes --out ../../maps
```

The board factory (`explore`, `playtest`, `adopt`, `sym.rs`, `design.rs`) stays in ants. It is
tooling, and a map is what it produces.

**Season 1's boards are already in unpushed commits.** They are rewritten before anything is
pushed (§0c.3). The rewrite goes with step 1 of §12, so that every commit that reaches `main`
still builds: removing the 32 boards alone leaves `tools/package.py` refusing an empty catalogue.

| Repository | Commit | What in it is a season map |
|---|---|---|
| ants | `463d9ef` *Draw season 1's thirty-two boards as designs…* | the 32 boards in `maps/` and the 32 recipes. The mapgen code in the same commit stays |
| web | `19db493` *Rewrite the book for season 1's thirty-two designed boards…* | `docs/tutorials/replays/real-match.json` (a replay carries its board), restored to its pushed version and re-captured on a basic board in step 4; the 32 `docs/tutorials/preset-*.json` specs and `maps.md`, which draw every season board from the cartridge when the book builds |
| soma, kalam | `221bd08`, `e6a2339` | only the names (the `[vars].presets` list, a claim example). These go away with presets anyway |

Older releases (`engine-df312c0458d9` and earlier) carry the generated boards they shipped with.
Those were never season 1's, and published releases are never re-cut.

---

## 4. The engine change (one digest, carried by the release that is already owed)

- **`worldgen(seeds[], map | maps, players?, max_turns?)`**: the board is **required**, either as
  an object or as one object per seed. `preset` is removed. With no catalogue, a board given by id
  has nothing to resolve against, so that form goes too.
- `build.rs`, `MAPS`, `catalogue()`, `pool()`, `presets()`, `for_seed()`, `Preset` and
  `NO_SUCH_PRESET` are deleted. `MapFile` loses `preset`; a file that still carries the key is
  still read, and the key is ignored. **The component contains no board at all**, so changing a
  basic board is not an engine-digest change.
- `MapFile::from_json` and `validate` do not change. Every board is still validated before it is
  played, whether it comes from Soma's upload check or from a runner.
- `finish` and the replay envelope already carry the board, so `replay-decode` and the viewer do not
  change.
- The `reference` binary takes `board:seed:turn` over the basic boards. `tools/package.py` drops
  `presets` from `cartridge.json`, keeps `maps` (now the five basic boards), and derives
  `limits.boards` from them.
- **Proving that no rule changed:** for all 32 season 1 boards (from the root folder), hash every
  turn's `observe`, `step` and `finish` output under a random and a greedy policy. Do it once
  through `worldgen(map=<object>)` and once through `worldgen(preset=<name>)` at HEAD. Every hash
  must match.

Season 1's boards are unreleased, and an ants release is owed anyway, so this is the only engine
digest the change costs.

**What this overturns** (in the book's *Adding a game*): *"a board edit is an engine-digest change
… there should not be"* a separate way to ship boards, and *"let the seed choose the board"*. Pair
now chooses the board, and the seed is still pair's, so a competitor still cannot choose the board
they play. What changes is that **the boards are no longer fixed for a season** (§6.3 names the
cost).

---

## 5. The schema (`0001_init.sql` and `0002_sessions.sql`, rewritten in place, pre-release)

```sql
-- seasons, in its CREATE TABLE:
    name   text NOT NULL,     -- "Summer 2026"; fixed at creation
    slug   text NOT NULL,     -- "summer-2026"; derived from name, fixed, the season's key everywhere
    CONSTRAINT seasons_name_shape CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 48),
    CONSTRAINT seasons_slug_shape CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 48
                                         AND slug NOT IN ('current', 'live', 'latest', 'new')),
    UNIQUE (game_id, slug),
    UNIQUE (id, game_id),    -- already there

-- A season's maps: uploaded by an admin at any time before the close, then enabled or disabled --
-- NEVER DELETED. The matches played on a map name it, it is public from its upload, and
-- season_map_events is the record of which boards a live season's ratings were earned on.
CREATE TABLE season_maps (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id   uuid        NOT NULL REFERENCES seasons (id),
    map_id      text        NOT NULL CHECK (map_id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),  -- the file's `id`
    players     smallint    NOT NULL CHECK (players >= 2),
    rows        smallint    NOT NULL,
    cols        smallint    NOT NULL,
    digest      text        NOT NULL,   -- sha256 of board::text, Postgres's canonical jsonb rendering
    board       jsonb       NOT NULL,   -- the cartridge's; never read here, only passed to worldgen
    enabled     boolean     NOT NULL DEFAULT false,   -- UPLOADED DISABLED: an upload pairs nothing
    added_at    timestamptz NOT NULL DEFAULT now(),
    added_by    uuid        NOT NULL REFERENCES users (id),
    -- One id and one board per season, for ever: there is no delete, so a map taken out of play is
    -- disabled and later re-enabled, never uploaded a second time.
    UNIQUE (season_id, map_id),
    UNIQUE (season_id, digest)
);

-- Every enable and disable, so "which boards were in play on 3 October" has an answer. Written in
-- the same statement as the flip. The upload writes none: added_at is the upload, and a map
-- uploaded and never enabled was never in play.
CREATE TABLE season_map_events (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),   -- built: (season_map_id, at)
    season_map_id uuid        NOT NULL REFERENCES season_maps (id),    -- collided inside one
    at            timestamptz NOT NULL DEFAULT clock_timestamp(),      -- transaction
    enabled       boolean     NOT NULL,
    by_user       uuid        NOT NULL REFERENCES users (id),
    cancelled     int         NOT NULL DEFAULT 0    -- pending matches a disable cancelled
);

-- matches: `preset text NOT NULL` becomes
    season_map_id uuid NOT NULL REFERENCES season_maps (id),

-- notifications (0002): `season int` becomes
    season text,             -- the slug
```

**Removed:** `[vars].presets`, the `pairing.presets` key and the `'presets'` kind in
`season_rule_spec()`/`season_rules_ok()`, and `matches.preset`. A season's maps are not a rule:
**`rules` stays immutable once the season opens, and `season_maps` is the one part of a season
that is allowed to change while it is live.**

**`number` stays, but only internally**: it is the ordinal the baseline carry uses
(`prev.number = created.number - 1`) and the order the season list sorts by. It is no longer in any
URL, route, input or response.

**Grants:** `runner_gate` gets `SELECT (id, map_id, board)` on `season_maps`, and
`matches.season_map_id`, for the claim. `kalam` gets the same for its db-mode `K_ROW` until N10.
Only Soma's admin routes write `season_maps`, and **no role is granted DELETE on it**, so a map
cannot be deleted even by mistake.

---

## 6. Soma

### 6.1 Routes

| Method | Path | Who | What |
|---|---|---|---|
| POST | `/v1/games/{game}/seasons` | admin | as today, plus **`name` (required)**. The slug is derived from it (§10) |
| PATCH | `/v1/games/{game}/seasons/{slug}` | admin | dates, rules and weight classes, before open, as today. `name` is refused |
| POST | `/v1/games/{game}/seasons/{slug}/close` | admin | replaces `…/seasons/current/close` |
| GET | `/v1/games/{game}/seasons/{slug}/maps` | **public** | every map the season has, enabled or not: `map_id`, `players`, `rows`, `cols`, `enabled`, `added_at`, matches played on it. `?enabled=1` narrows to the enabled ones |
| GET | `/v1/games/{game}/seasons/{slug}/maps/{map_id}` | **public** | one map with its **board** and its enable/disable history. A board is public the moment its upload succeeds |
| POST | `/v1/games/{game}/seasons/{slug}/maps` | admin | **upload one map file** (a board is ≤ ~10 KB). It is stored **disabled**. The web page sends one request per file, so each file gets its own answer |
| PATCH | `/v1/games/{game}/seasons/{slug}/maps/{map_id}` | admin | `{"enabled": true}` enables it (repeating the engine check), and `false` disables it (§6.3). **There is no DELETE** |
| GET | `/v1/games/{game}/leaderboard?season={slug}` and every other `?season=` | public | the slug replaces the number |

### 6.2 The upload

In this order, each step refusing with its own reason:

1. an admin (`users.role`), a season that exists and is not closed: `season_closed`;
2. a header of the right shape (`id` a slug, `players`, `rows` and `cols` whole numbers):
   `map_bad_header`;
3. inside `games.manifest -> 'limits' -> 'boards'`: `map_outside_limits`, naming the bound;
4. **the node's engine is the season's engine** (`/pkg/cartridge/engine-digest` against
   `seasons.engine_digest`): `engine_mismatch`, naming both. Validating against a different engine
   would prove nothing;
5. `tb.ants.worldgen` accepts it: `map_invalid`, carrying the engine's code and message;
6. the insert, **disabled**: `map_id_taken` or `map_duplicate` (409) from the two unique keys. The
   answer names the existing map and says whether it is disabled, because enabling that map is the
   fix.

The web's upload list shows each file's answer. **Built:** the two admin map routes meter at
`per_admin_board_rate` (5 rps, burst 40) rather than the 1 rps every other write gets, because a
season's thirty-odd boards arrive together; the engine's refusal reaches the workflow only as a code,
so the 422 points at `tinybrains maps check`, which prints the reason. **Enabling repeats steps 4 and 5.** An engine
*patch* (`bootstrap` without `ENGINE_RELEASE`) moves a live season's `engine_digest`, so a map
checked at upload may be checked by a different engine by the time someone enables it.

### 6.3 Changing maps while a season is live

- **Uploading** a map changes nothing about pairing: it is stored disabled. **Enabling** it, or
  re-enabling it, takes effect at the next pair run. Pairing's coverage rule sends a version to the
  board it has played least, so every version that still wants matches is drawn to a newly enabled
  map first. A **settled** version creates no demand, so it meets a new map only as someone's
  opponent.
- **Disabling** a map sets `enabled = false` and, **in the same statement, cancels the `pending`
  matches on it** (`status 'cancelled'`, `withdrawn_reason 'MAP_DISABLED'`), and records how many in
  its event row. **Claimed and running matches finish and are counted** (§0b.4). A cancelled trial is
  re-paired on the next map by the rule that already handles a cancelled trial (`clocks.md`, the
  trial table). A claim and a disable lock the same row, so whichever commits first decides whether
  that match is played or cancelled. Either outcome is valid.
- **A disabled map stays public**, keeps its matches and its place in the Matches filter, and can
  be enabled again at any time before the close.
- **No enabled maps** is allowed and means nothing is paired, the same paused state as having no
  live season. Candidates wait for their trial instead of being rejected. **Every new season starts
  this way**, since its uploads land disabled. The admin page warns until at least one map is
  enabled.
- **The cost, stated plainly:** a live season's ratings are earned on whichever boards were enabled
  at the time. Standings do not say which boards those were. `season_map_events` and each match's
  `season_map_id` record it.

### 6.4 Pairing

- `P_DEMAND_DOC`: `limits.presets` becomes `limits.maps`, the season's enabled `season_maps` (`id`,
  `players`, ordered by `added_at, map_id`), and `played` counts per `season_map_id`. The
  `[vars].presets` input is removed. **The season is the only source.**
- `tb-pairing`: `Preset {name, players}` becomes `Map {id, players}`. The algorithm does not change:
  least-played first, ties broken by the seed, and only boards the roster can seat.
- `P_TRIALS` rotates over the enabled maps the season's baselines can seat, in the same order.
- `P_INSERT` takes a `season_map_id`, **refuses one that is disabled or belongs to another
  season**, and **derives `seat_count` from its `players`**, refusing a seat list of any other
  length. Today it trusts the plugin's count. A map disabled between pair's read and its insert
  therefore gets no new match.

### 6.5 Admission — its source does not change

`games.reference_observations` stays and still comes from the release, now generated over the five
basic boards. The only change is §2's rule: because the reference set spans the envelope and every
upload must fall inside it, **an adapter admitted once can play any map a season adds later**. That
is the property live changes need.

### 6.6 The claim — the board travels with the match

`soma-runner-claim`'s row read and Kalam's `K_ROW` join `season_maps` and send `map_id` and
**`map`** (the board) in place of `preset`. The largest board today is 10,082 bytes, it is sent
once per match, and a match lasts a thousand turns. This is the same argument that moved `turn_ms`
onto the claim: the runner gets the value from the one place that owns it. It fetches nothing and
caches nothing, and it needs no change when a season's maps change.

### 6.7 Other reads, and the notifications

`season_json` gains `name` and `slug`, drops `number`, and gains
`maps: {enabled, disabled, players: [min,max], sides: [min,max]}` over the enabled ones. `GET /v1/games/{game}` drops the manifest's `presets`. Match reads return
`map_id` in place of `preset`, and `?preset=` becomes `?map=`. Count's notification text reads
`map_id`. The season-closed notification reads *"Summer 2026 has closed"*, and its link is
`/leaderboard?season=summer-2026`. `current_season(game, number?)` becomes
`current_season(game, slug?)`.

### 6.8 The image

Soma's Dockerfile `cartridge` stage also copies `tb-ants.wasm` and its plugin manifests. The
package loads the plugin under a name held in a var, and web's `scripts/setup/sign-plugins.sh` signs
it with the rest. The self-load's check that "both plugins are loaded" becomes three. The image still
carries no season maps.

---

## 7. Kalam

- `tb-match`'s `world` task: `"map": var("data.row.map")`, `"players": var("data.row.seat_count")`.
  `preset` is removed.
- The replay envelope keeps `map_id` and `map` and drops `preset`. The schema is pre-release, so the
  local stack is rebuilt and its old replays go with it. No reader keeps a fallback.
- `K_ROW` (db mode) joins `season_maps` exactly as the gate's route does. **The two copies must
  change together**, as the root guide already warns for all eight gate statements.
- The runner image does not change when a season's maps change.

## 8. Web and the book

- **Creating a season** (`SeasonsAdmin.tsx`): a **name** field with a live preview of its slug,
  and a note that neither can be changed. After the create call succeeds, a **map drop zone**
  (several `.json` files) uploads each file and lists every file's result. This is how production
  seasons receive their maps. The uploads land **disabled**, and the page then shows the list with
  its switches and an **Enable all**.
- **Season settings → Maps**, on scheduled and live seasons: the list (id, seats, size, when it was
  added, matches played on it, enabled or not), **add** (the same drop zone), and an
  **enable/disable** switch per map. Disabling asks for confirmation with the number of pending
  matches it will cancel, and says that running ones will still count. There is no delete button,
  because there is no delete. A closed season's list is read-only.
- **Slugs everywhere**: routes and `?season=<slug>`; `lib/selection.ts` keeps a slug; the `Shell`
  switcher, breadcrumbs, footer and `Leaderboard` show the **name**; the close confirmation asks the
  admin to type the slug.
- **The season's maps are public**, so every visitor sees them: a *Maps* page per season draws each
  board at turn 0 with the viewer's own component (`worldgen` with the board, then `replay-decode`,
  so there is no second engine), with its seats and size. A disabled map, including an upload not
  yet enabled, is shown as disabled: it is public from the upload (§0b.1), but it is not being
  played.
  **Home**: the *Maps* row links there and counts the enabled maps. **Matches**: the *Map* filter
  lists every map the season has, disabled ones included, since they have matches. **Match**:
  `map <id>`, linking to the board.
- **`scripts/check/configs.sh`**: the presets block (lines 170–200) is replaced by one check: kalam's
  `MAX_SEATS` is at least `limits.boards.players[1]`.
- **A dev script**, `scripts/dev/upload-maps.sh <dir> <season-slug>`, loads `tinybrains/maps/` into
  the local season, so the local stack plays season 1's boards without their being committed.
- **The book**: *Adding a game* §Boards describes the upload, the engine's validation, the envelope
  and the five basic boards. Its `worldgen` row says "a board object". The maps chapter
  (`games/ants/maps.md`) describes how boards are made and shows the **basic** boards. The 32
  `preset-*.json` specs and `replays/real-match.json` are replaced by the basic boards. *Testing*
  §Match files gains `map` and loses `preset`. The adapter pages size their budget on the envelope's
  largest board.

## 9. The CLI and the starter

- **Match file** (`cli/src/matchfile.rs`, the only specification): a row names `map`, either an id
  resolved in the registry's `maps/` (the basic boards) or an inline board object. `preset` is
  removed. `seat_count` is checked against the board's `players`.
- `tinybrains env --maps <ids | dir>` draws boards by seed. By default it uses the release's basic
  boards, and it can be pointed at `tinybrains/maps/`. The old seed-picks-the-board rule moves out
  of the engine and into the training environment, the one place that still needs it.
- `tinybrains maps check <file…>` (new, small): runs `worldgen` on each file under the registry's
  engine and checks it against `limits.boards`. It performs the same checks as Soma's upload, so an
  admin can check a folder before uploading it.
- A CLI release, and the book's `CLI_VERSION` bumped to it (N23).
- **ants-starter**: pin the new release. Its two match files name a basic board in place of `open-2`
  (which is already stale: no preset of that name exists). The starter itself holds no maps; they
  come from the release (N22's rule that the boards travel in the release).

---

## 10. Season names and slugs

| Question | Answer | Why |
|---|---|---|
| The name | free text, 1–48 characters, trimmed ("Summer 2026", "FireAnts 2026"), **required** on create | the user's names; a season with a generated name would need one anyway to have a slug |
| The slug | lower-case the name, turn each run of anything outside `[a-z0-9]` into one `-`, trim the ends: `summer-2026`, `fireants-2026` | readable, and predictable from the name |
| Unique | the slug, per game; refused as `season_slug_taken` (409), which names the season that holds it | two names that give one slug ("Summer 2026", "Summer-2026") would be one URL |
| Reserved | `current`, `live`, `latest`, `new` | so no season can shadow a route segment, now or later |
| A name that gives no slug | ("🔥 🔥") refused as `season_name_unusable` | every season must have a key |
| Changing it | **never**, not even before the season opens; `soma-seasons-update` refuses `name` | the user's call; also, a slug that never changes keeps every shared link working |
| Where it shows | the name wherever a person reads a season; the slug in every URL, parameter, notification link and `notifications.season` | "slug everywhere" |

---

## 11. What must stay true — additions to the root `CLAUDE.md`

- **Season maps are never released, and never committed while their season runs.** They live in
  `tinybrains/maps/` and reach the platform only through an admin upload. After the season closes
  they are pushed to a backup repository, never to ants. The five basic boards in `ants/maps/` are
  the only boards in a code repository or a release.
- **An upload changes nothing until an admin enables it**, and an enable checks the board under the
  season's engine again.
- **The basic boards define the envelope.** `limits.boards` is derived from them, admission's
  reference set is generated from them, and every upload must fit inside that range. Changing a
  basic board changes what an admitted adapter is promised it will face.
- **The engine judges every map, and nothing downstream reinterprets it.** Soma validates by calling
  `worldgen` on its own node, which must run the season's engine. The platform reads only the header.
- **A season's maps are the one part of a season that changes while it is live, and a map is never
  deleted.** Maps are enabled and disabled. A queued match pins its `season_map_id`, and disabling a
  map cancels only its `pending` matches; running ones count.
- **A map is public from the moment its upload succeeds**, board included.
- **The board travels with the claim.** `soma-runner-claim` and Kalam's `K_ROW` change together
  until N10.
- **A season's slug is its key, and it never changes.**

---

## 12. Order of work, and how each step is proved

| # | Repository | Work | Proved by |
|---|---|---|---|
| 0 | ants, web | **decided (§0c.3)**: move the 32 boards and recipes to `tinybrains/maps/`, then rewrite the unpushed commits of §3 so no season board is in any of them. Done together with step 1, so every pushed commit builds | `git log -p origin/main..main` shows no season board, in ants or in web |
| 1 | ants | five basic designs; the engine change (§4); `reference` over the basic boards; `limits.boards`; mapgen `--recipes/--out` | `build.sh` green; turn-by-turn hashes identical to HEAD on all 32 season boards; baselines' conformance over the new reference set |
| 2 | soma | the schema (§5); routes (§6.1) with the upload (§6.2) and enable/disable (§6.3); pairing; the claim; slugs; the plugin in the image | `scripts/verify/run.sh` scenarios: an upload stored disabled and paired on by nothing until it is enabled; an enable refused when the engine rejects the board; upload refused outside the limits, refused by the engine, refused on a closed season, refused as a duplicate while the original is disabled; a disable cancelling only pending matches, and a running match on it still counted; a re-enable pairing again; an insert refused on a disabled map and on a wrong seat count; a claim carrying the board; a duplicate slug and a rename both refused; no role able to delete a map. `smoke.sh` on slugs and on the public map reads |
| 3 | kalam | `worldgen` with the board; `K_ROW`; envelope | a local match played end to end; `tinybrains conform` on its replay |
| 4 | web | create with name and upload; the Maps panel and the public Maps page; slugs; labels; `configs.sh`; the dev upload script; the book | the pages at phone width, with a two-seat and an eight-seat board; a live add, disable and re-enable on the local stack; `configs.sh` green |
| 5 | cli, ants-starter | `map` in match files; `env --maps`; `maps check`; CLI release; the starter's pin | the starter's CI playing both match files against the release |
| 6 | local stack | a fresh database (the schema is rewritten), `bootstrap`, a season created by name, `upload-maps.sh ../maps summer-2026` (it uploads, then enables) | smoke; a ladder that pairs every map the roster can seat; a map disabled while matches are queued and running |
| — | at every season's close | push that season's maps and recipes from `tinybrains/maps/` to the backup repository | the repository holds a file for every `map_id` `season_maps` has for the season, disabled ones included |

The ants release in step 1 is the one already owed. The tag is the user's call, and the release must
be published before step 2's image can build without `--build-context`.

---

## 13. Still open

**Nothing is open in the design.** Three things are left to the user and none of them blocks the
build: the backup repository's name and home, chosen at the first season's close; the ants release
tag; and the go-ahead to start building, which begins with steps 0 and 1 in ants.
