# Soma — M0 scope

The smallest Soma that makes TinyBrains real. Full module map in
[`../platform.md`](../platform.md); system context in [`../architecture.md`](../architecture.md).

**The one loop M0 must support:**

> A competitor signs in, submits a model, sees it appear on a leaderboard, and watches a replay of
> it playing.

Everything that does not serve that sentence is deferred. One game (`ants`), invite-only, one
implicit season, no CLI.

Soma owns the first and third clauses — the sign-in, the record of the submission, and every read
that renders a ladder or a replay. It owns none of the middle: admitting a model and playing it
belong to a **game manager** service that writes the same database and is not yet designed (§3).

---

## 1. Screens

Five. The API exists to serve exactly these.

| | Screen | Needs |
|---|---|---|
| 1 | **Leaderboard** | ranked models for a game, per ladder — each weight class, plus `open` |
| 2 | **Version** | one submitted version: its two ratings, size, status and recent matches |
| 3 | **Replay** | a match's players and result, plus the replay blob to render |
| 4 | **Submit** | name a GitHub release, then watch it go from testing to active |
| 5 | **My versions** | every version I've submitted per game, and which one is contesting |

---

## 2. The API

Eleven endpoints. Base path `/v1`. JSON in, JSON out.

| Method | Path | Screen | Auth |
|---|---|---|---|
| `GET` | `/auth/github` | sign-in | — |
| `GET` | `/auth/github/callback` | sign-in | — |
| `GET` | `/me` | shell | session |
| `DELETE` | `/session` | shell | session |
| `GET` | `/games` | shell | — |
| `GET` | `/games/{game}/leaderboard` | 1 | — |
| `POST` | `/submissions` | 4 | session |
| `GET` | `/models` | 5 | session |
| `GET` | `/models/{id}` | 2 | — |
| `GET` | `/matches` | 2 | — |
| `GET` | `/matches/{id}` | 3 | — |

Four deliberate merges, each removing an endpoint:

- **A submission *is* a model version.** Each `POST /submissions` writes a new row with the next
  version number and returns its id in `testing`; the frontend polls `GET /models/{id}` until it
  reads `active` or `rejected`. So there is no submissions-read endpoint and no second identifier —
  a model id *is* a submission id. Only one may be in flight: a submission arriving while another
  is still `testing` gets `409`.
- **`GET /matches?model={id}`** covers a model's match history; there is no nested route.
- **`GET /models?owner=me`** covers "my models"; there is no `/me/models`.
- **`GET /matches/{id}`** returns a signed replay URL pointing straight at blob storage, so there
  is no replay-download endpoint and the blob never transits the API.

`/games` stays despite there being one game: it keeps the shell from hardcoding a ladder list, and
the slug it returns resolves the visualizer by convention (`/cartridges/{slug}/viz.js`). Serving that
path from the database instead is the first thing to add when a second cartridge disagrees.

### Shapes

```jsonc
// GET /games
[{ "id": "ants", "name": "Ants" }]

// GET /games/ants/leaderboard?ladder=micro&limit=50&cursor=
//   ladder = nano | micro | mini | small | large | open
{ "entries": [{ "rank": 1, "model_id": "…", "owner": "codetiger", "version": 7,
                "class": "micro", "size_bytes": 35812,
                "rating": 1487, "provisional": false, "matches": 214 }],
  "next_cursor": null }

// GET /models/{id}          — one version, not one competitor
{ "id": "…", "owner": "codetiger", "game": "ants", "version": 7,
  "repo": "codetiger/ants-brain", "release_tag": "v1.2.0",
  "class": "micro", "size_bytes": 35812,   // null until admitted
  "status": "active",        // testing | active | superseded | rejected
  "ratings": {               // one per ladder; empty while testing or rejected
    "micro": { "rating": 1487, "provisional": false, "matches": 214 },
    "open":  { "rating": 1302, "provisional": false, "matches": 189 } },
  "reject_reason": null, "created_at": "…" }

// GET /models?owner=me&game=ants   — the submission history, newest first

// GET /matches/{id}   — stored as parallel seat arrays, served as objects
{ "id": "…", "game": "ants", "seed": 88213, "reason": "hills_razed",
  "players": [{ "seat": 0, "model_id": "…", "owner": "codetiger",  "model_version": 5, "rank": 1, "score":  4 },
              { "seat": 1, "model_id": "…", "owner": "baseline-greedy", "model_version": 1, "rank": 2, "score": -1 }],
  "replay_url": "https://…?sig=…", "played_at": "…" }

// POST /submissions
// in:
{ "game": "ants", "repo": "codetiger/ants-brain", "release_tag": "v1.2.0" }
// out:
{ "model_id": "…", "version": 8, "status": "testing" }
// 409 if a version is already testing for this (owner, game)
// 409 if this (repo, release_tag) was already entered for this game
```

### Submission admission

**Soma does not admit models.** It records the intent and reads back the outcome.

A submission names a GitHub release. Soma writes one `models` row as `testing` carrying `repo` and
`release_tag`, and little else — it cannot state the model's size, class or hashes, because
computing them means fetching and parsing an ONNX file. That is the game manager's work.

Two refusals, both database constraints rather than application checks: `409` if this competitor
already has a version `testing` for this game, and `409` if this `(repo, release_tag)` was already
entered. They hold even though two services write the table.

Everything after the insert belongs to the game manager — fetch the release, verify the assets,
compute the compressed size and the weight class, run whatever load check it wants, then fill the
admission columns and move the status: `testing → active`, demoting the previous `active` to
`superseded` and seeding the new version's two rating rows; or `testing → rejected` with a reason.

**The cost of that split, stated plainly.** A submission sits in `testing` until the game manager
picks it up, and while it does, its owner cannot submit again. Sweeping a `testing` row nobody ever
admits belongs to whoever admits them. Until the game manager exists, M0 has no end-to-end loop.

---

## 3. What Soma does not own

The match loop belongs to a separate **game manager** service, not yet designed. It reaches the
same Postgres directly and owns:

| | |
|---|---|
| `matches` | every match played — seats, ranks, scores, replay key |
| `ratings` | TrueSkill per `(model, ladder)`, including the promotion seed |
| `models`, after insert | the admission columns, and every status transition |

So Soma has **no fleet-facing endpoints at all** — no roster, no result ingest, no heartbeat, and
no shared secret, because there is nothing to post to. The eleven above are the whole surface.

`models` therefore has two writers, a deliberate exception to [`../platform.md`](../platform.md)
§5's one-writer-per-store invariant. It is safe only because the rules that matter are database
constraints rather than either service's code — see [`schema.md`](schema.md) §5.

---

## 4. Data

Five tables. Nothing else. Full schema in [`schema.md`](schema.md).

| Table | Holds | Written by |
|---|---|---|
| `games` | slug, display name | seeded |
| `users` | github id, handle, role. **Baselines are users too** — one per reference opponent, github id null | Soma |
| `models` | **one row per submitted version** — source release, then class, size, hashes, status | Soma inserts · game manager admits |
| `ratings` | **one row per (model, ladder)** — μ, σ, match count, and the seed it was promoted with | game manager |
| `matches` | game ref, cartridge hash, seed, reason, replay key, and the seat arrays | game manager |

Soma holds no blobs. A submission is a reference to a GitHub release; replays live in object
storage and Soma only signs a URL to one.

---

## 5. Modules

Against the seventeen in [`../platform.md`](../platform.md):

**In** — S1 `gateway` (thin), S2 `identity` (GitHub only), S4 `submissions` (the row, not the
admission), S5 `models`, S8 `leaderboard` (an indexed query, no cache tier), S15 `replays`
(signed URLs only).

**Moved to the game manager** — S6 `results`, S7 `rating`, S12 `roster`, S14 `artifacts`, and the
admission half of S4. Between them these were most of the platform's original weight; what is left
in Soma is a system of record and a login.

**Deferred, each to a hardcoded stand-in** —

| | Module | M0 stand-in | Unblocks it |
|---|---|---|---|
| S3 | `quotas` | a constant in config | public signup |
| S10 | `registry` | one game manager, reaching the database directly | more than one server per game |
| S9 | `seasons` | one implicit open season | the second season |
| S11 | `commands` | restart the server | cartridge upgrades without downtime |
| S13 | `policy` | a static config file | tuning the ladder without a deploy |
| S16 | `events` | direct in-process calls | splitting into services |
| S17 | `audit` | application logs | more than one admin |

Also deferred: the Pareto frontier and TinyBrain Index (rating alone ranks at M0), cross-game
standings, CLI tokens, replay expiry, and trial matches.

The frontier is the painful cut — it is the actual headline of the competition. It is deferred
only because it is a pure read projection over data M0 already stores, so it can land later
without a migration.

---

## 6. Done when

Soma is done when a competitor can sign in, submit a release, and see every screen render correctly
from data in the database — with no endpoint outside the eleven above.

That is deliberately testable without the game manager: seed `games`, insert `models`, `ratings` and
`matches` rows by hand, and all five screens must work. **The loop itself does not close until the
game manager exists** — nothing promotes a submission out of `testing`, and nothing produces a match.
Soma being finished and TinyBrains being playable are now two different milestones, and it is worth
not confusing them.

---

## 7. Open decisions

1. **Session mechanism** — cookie or bearer token. Cookie is simpler now; token is what the CLI
   will need, so choosing cookie means writing the token path twice.
2. **Which ladder the leaderboard opens on.** `open` is the fullest and the most legible to a
   newcomer; a weight class is where the thesis actually lives. Defaulting to `open` and surfacing
   the classes as tabs is the likely answer, but it decides what TinyBrains looks like on first
   visit.
3. **Whether Soma checks the release exists at submission time.** One call to GitHub would catch a
   typo immediately instead of leaving the competitor to discover it as a rejection minutes later.
   The cost is that submitting now depends on GitHub being reachable, and that Soma starts knowing
   something about the shape of a submission it otherwise just records.
4. **Which release assets are canonical** — fixed names (`model.onnx`, `adapter.json`) or named in
   the release body. Soma never opens the release, so this is the game manager's contract, but it is
   the part a competitor has to be told and it belongs in the published rules.
5. **Whether baselines appear on the leaderboard** or are filtered to a reference line. `role` makes
   it a display decision either way.

Four decisions left with the match loop and now belong to the game manager: rating-update
synchrony, sigma inflation on promotion, the admission timeout, and whether a `testing` version
plays anything.
