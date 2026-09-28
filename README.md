# soma

Soma is TinyBrains' public API, its schema and the life cycle of a model version: sign-in,
submissions, admission, trials, promotion, pairing, rating and seasons. It is an Orion 1.11.1 package
(REST channels, cron clocks, workflows, connectors and two Rust/wasm plugins) plus the Postgres
migrations every package shares, shipped as the node image `ghcr.io/tiny-brains/soma`.
[Kalam](https://github.com/Tiny-Brains/kalam) runners play the matches Soma queues, and
[web](https://github.com/Tiny-Brains/web) is the site in front of it and the local stack.

**Owns:** multi-provider sign-in and sessions · public reads · submissions and their presigned uploads ·
seasons, their boards and baselines · admission, pairing, trials, promotion, rating, withdrawal and
the season close · the runner gate `/v1/runner/*` · notifications · the schema and the
`runner_gate` grants. **Does not:** run any model -- a submission is admitted on an admitting
runner and matches are played on runners (Kalam) · write replays · implement game rules (the Ants
cartridge) · decide deployment addresses, credentials or replica counts.

```text
browser ──▶ web nginx ──/v1/──▶ ┌── Soma node × N (Orion, cluster mode) ────────────────┐
Kalam runner ──/v1/runner/*───▶ │ routes · runner gate · clocks · tb.rating · tb.pairing │── SQL ──▶ Postgres
                                │ tb.ants (map checks) · no models entity                │
                                └──┬─────────────────────┬───────────────────────────────┘
                     presign PUT/GET│                     │ HEAD + GET the manifest
competitor ──presigned PUT──▶ models bucket (public-read) ◀── runners fetch by digest (the admitting one first)
runner ──presigned PUT──────▶ replay bucket (private)     ◀── browsers, presigned GET
```

Soma and Kalam never call each other: they meet in the schema. A runner holds no database
credential and reaches the queue only through the gate's routes, which run the match statements as
the `runner_gate` role.

## Quick start

The local stack is web's `docker-compose.yml` (Postgres, Redis, MinIO, Soma, the Orion console, the
site); its README covers the first run (`scripts/setup/init.sh`, the OAuth App). To run this
checkout in it:

```sh
docker build -t tinybrains/soma:dev .                         # add --build-context ants=../ants/dist for an unreleased engine
cd ../web && SOMA_IMAGE=tinybrains/soma:dev docker compose up -d
docker compose logs -f soma                                   # wait for "==> loaded: tb.rating, tb.pairing and tb.ants are live"
curl -fsS http://127.0.0.1:8080/v1/games
```

The image has two commands. `bootstrap` runs once before any node: it creates `orion_state`,
applies the migrations to an empty database (and refuses a database whose recorded schema digest
differs), registers the game, sets the `runner_gate` password, declares the engine digest and
registers the cartridge's manifest and reference observations. It seeds nothing an admin makes: a
fresh platform has no season until an admin creates one. `serve` (the default) migrates
Orion's state, loads the package into the node, and stops the node if a plugin failed to load or a
channel is quarantined.

## Interface

**Auth modes.** *Public*: no credential. *Session*: an HS256 JWT in the HttpOnly `soma_session`
cookie (issuer `soma`, 30 days), checked against `live_sessions` inside every query, so revocation
is immediate. *Admin*: a session whose live `users.role` is `admin`, read off the row, never off the
cookie. *Season admin*: a platform admin OR a live member of the season's `season_admins`, resolved
from the route's `{game}`/`{slug}` and read off the row on every call, so a removal takes effect at
the next request. *Runner*: an `Authorization: Bearer` JWT with `aud: runner`, signed with
`RUNNER_TOKEN_SECRET`, ten minutes, checked against `live_runners` inside every statement. Every
channel but `/v1/admin-check` also has an address-keyed `rate_limit` applied before auth, and authed
channels add a per-principal quota.

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/v1/auth-providers` | Public | The sign-in buttons the deployment serves (`[{slug,label}]`), for the chooser page (a sibling path: `/v1/auth/*` is the sign-in channel's) |
| GET | `/v1/auth/{provider}` | Public | Redirect to that provider (state, PKCE, `?next=`); the same channel serves `/{provider}/callback` and sets the cookie. GitHub in the block, others via `[oauth2_login.providers.*]` |
| GET · PATCH | `/v1/me` | Session | Current user, bio, commenting switch and `admin_of` (the seasons the caller administers), served from its session entry in Redis until a sign-out, a revocation or five minutes · `display_name`, `bio` (422 `bio_word_listed`) |
| GET | `/v1/me/candidates` | Session | The caller's versions still being admitted or on trial; uncached, polled with the bell |
| GET | `/v1/me/matches` | Session | The caller's matches in every state, queued and cancelled included, as cards with `mine` on each seat |
| GET | `/v1/me/matches/{id}` | Session | One match the caller has a seat in, any status, with a signed replay URL: a trial in progress or a rejected candidate's |
| GET | `/v1/me/comments` | Session | `match` or `model`: your held comments on that host |
| GET | `/v1/me/models/{id}/story` | Session | The writer's view: the approved text and the held edit with its `hold_tag` |
| GET | `/v1/me/notifications` | Session | Feed: `category`, `unread`, `since`, `cursor`, `limit`; unread count |
| POST | `/v1/me/notifications/read` | Session | `ids`, or `all` with an optional `category` |
| GET · PATCH | `/v1/me/notification-settings` | Session | Per category `app`, `push`, `level`; 409 `category_locked` |
| GET | `/v1/sessions` | Session | Live sessions |
| DELETE | `/v1/sessions/{sid}` · `/v1/session` | Session | Revoke one (`others` = all but this one) · sign out |
| GET | `/v1/admin-check` | Session | **204** admin, **401** no or revoked session, **403** signed-in non-admin; no body |
| GET | `/v1/status` | Public | Queue, throughput, how far each clock is behind, and `admitters`: how many machines could serve the admission queue |
| GET | `/v1/games` · `/v1/games/{game}` | Public | Games with their current season · one game: `about`, effective limits (`limits.boards`), weight classes with their memory numbers |
| GET | `/v1/games/{game}/leaderboard` | Public | `ladder`, `season`, `limit` ≤ 200, `cursor` |
| GET | `/v1/private/...` | Session | The member's copy of every season-scoped public read -- seasons, leaderboard and series, podium, maps, playing, matches (list, one, frame, related), a match's thread (`/v1/private/threads`), versions, models -- with the same shapes: the same statement with the session's claims, so a private season answers to whoever `season_visible()` lets see it. Uncached |
| GET | `/v1/games/{game}/leaderboard/series` | Public | `ladder` (open), `since` (season open), `points` (60, 2..200), `season`: per version the rating and rank at each edge, from the hourly snapshots |
| GET | `/v1/games/{game}/picks` | Public | Live picks as cards in order, with `pick_id` and `position` |
| GET | `.../seasons/{slug}/podium` | Public | The frozen podium per ladder, each place with its owner's latest match |
| GET · POST | `/v1/games/{game}/seasons` | Public · Admin | Seasons with counts (public seasons to a stranger) · create `{name, submissions_open_at, submissions_close_at, visibility?, entry?, fleet?, providers?, admins?, rules?, weight_classes?}` (private forces restricted) |
| PATCH | `/v1/games/{game}/seasons/{slug}` | Season admin | Edit window, rules, weight classes before open; name and slug are refused |
| POST | `/v1/games/{game}/seasons/{slug}/featured` | Admin | Make a public season the game's featured one; a private season is refused |
| PATCH | `/v1/games/{game}/seasons/{slug}/fleet` | Admin | Change the fleet policy `{matches, admissions}` (each `own`\|`platform`\|`both`) while live |
| PATCH | `/v1/games/{game}/seasons/{slug}/entry` | Admin | Narrow a scheduled season's entry, `open` → `restricted`, and nothing else: visibility is fixed at creation and entry never widens |
| POST | `/v1/games/{game}/seasons/{slug}/close` | Season admin | Request a close; 202, consumed by the withdraw clock. Creating a season stays a platform admin's |
| GET · POST | `/v1/games/{game}/seasons/{slug}/rounds` | Admin | The rounds document (every round, the finals' progress, each version's games in the current round, the fill, the capacity) · schedule `{kind: round\|finals, games, starts_at?, sigma_floor?, mu_shrink?, warn_minutes?}`; 409 `round_waiting`, `finals_scheduled`, `window_open`, `admitting`; 422 `round_invalid` |
| PATCH | `/v1/games/{game}/seasons/{slug}/rounds/{n}` | Admin | A waiting round's numbers, start or `cancel: true`; a started one's `games` alone (409 `round_started`) |
| PATCH | `/v1/games/{game}/seasons/{slug}/fill` | Admin | The idle fill `{enabled, games?, headroom?}` while live; 422 `fill_invalid` |
| GET · POST · DELETE | `.../seasons/{slug}/participants` | Season admin | Participants (resolved and waiting) · add in bulk (`logins`, `provider?` default github, a null login is a provider wildcard) · remove one |
| GET | `.../seasons/{slug}/admins` | Season admin | The season's admins by platform handle |
| POST · DELETE | `.../seasons/{slug}/admins` | Admin | Assign · remove a season admin by handle (bumps that account's session) |
| GET · POST | `.../seasons/{slug}/runner-keys` | Season admin | `{admissions, keys}`: whether anything can admit for this season (`queued`, `admitters`, `reach`), and its keys whoever minted them, each with its runners (`live` is `live_runners`') · mint a key bound to this season |
| DELETE | `.../seasons/{slug}/runner-keys/{key}` · `.../runners/{runner}` | Season admin | Revoke one of the season's keys · stop one of its runners; 404 outside the season |
| GET | `.../seasons/{slug}/audit` | Season admin | The season's audit lines (`audit_log.season_id`, derived by a trigger), `action` prefix, `cursor` |
| GET · POST | `.../seasons/{slug}/notify` | Season admin | `{recipients, sends}` · `{subject, link?}` to the season's people (entrants, pinned participants, its admins); 422 `no_recipients` |
| POST | `.../seasons/{slug}/maps/import` · `.../baselines/import` | Season admin | `{from, maps? \| baselines?}`: copy another season's boards (switched off) or baselines (new versions over the same bytes, re-admitted, landing switched off); `{imported}`; 404 `unknown_source` |
| GET | `.../seasons/{slug}/maps` · `.../maps/{map_id}` | Public | A season's boards, enabled or not (`?enabled=`, `?boards=`) · one board and its history |
| POST · PATCH | `.../seasons/{slug}/maps` · `.../maps/{map_id}` | Season admin | Upload one map file named `size-terrain-Np-Hh`, stored disabled (422 `map_name_pattern`, `map_name_players`, `map_name_hills`) · `{"enabled": bool}` |
| GET · POST | `.../seasons/{slug}/baselines` | Season admin | Baselines and refused uploads · `{name, weights_hash, manifest_hash}`, answered with two presigned PUTs |
| PATCH | `.../seasons/{slug}/baselines/{baseline}` | Season admin | `{"enabled": bool}`; `{baseline}` is the slug of its name |
| POST | `/v1/games/{game}/models` | Session | Create an entry `{name}` |
| GET | `/v1/models` | Session | The caller's versions with ratings and ranks; `?game=` |
| GET · PATCH | `/v1/models/{id}` | Public · Session | An entry and its versions · `{name, retired}` |
| GET | `/v1/models/{id}/season` | Public | Record, last five, best win and worst loss on Open, rank now and a week ago |
| GET | `/v1/models/{id}/rivals` | Public | Per opposing model this season: played, won, lost; most losses first; `limit` ≤ 100 |
| GET · PUT | `/v1/models/{id}/story` | Public · Session | The approved story (`title`, `body`, `featured`, `updated_at`), 404 while none is public · `{title, body}` (≤ 80, ≤ 20,000) replaces it, or holds it on a listed word while the public keeps the old text; 400 `story_invalid` (a one-line title ≤ 80, text 1–20,000); the owner, or an admin for a baseline's |
| PATCH | `/v1/versions/{id}` | Session | `{note}` (≤ 120, blank clears); 422 `note_word_listed` |
| GET | `/v1/versions/{id}` | Public | One version once public (`active`, `disabled`, `superseded`), else 404: status, ladders with rank and field, trial, note |
| GET | `/v1/me/versions/{id}` | Session | One of the caller's versions in any status (an admin's for a baseline too), the same shape |
| GET | `/v1/games/{game}/submission` | Session | Whether the caller may submit, and why not; `?model=` |
| POST | `/v1/submissions/reenter` | Session | `{game, model, season, from}`: the entry's standing in `from` entered into `season` over the same bytes (`bytes_of`), no upload; the submission's refusals, plus 404 `nothing_to_reenter` |
| POST | `/v1/submissions` | Session | `{game, model, weights_hash, manifest_hash, note?}`: a `testing` version and two presigned PUTs; the same hashes again re-sign them; 422 `note_word_listed` |
| GET | `/v1/matches` · `/v1/matches/{id}` | Public | `season`, `model`, `version`, `owner`, `map`, `class`, `ladder`, `outcome`, `players_min/max`, `sort` (newest, closest, upset, longest, discussed, each with its own cursor), `since`, `top=true`, `vs=<model>` beside `model=` (400 `vs_needs_model`, `sort_invalid`), `cursor`, `limit` ≤ 60; `total` counts to 10,000 and `total_capped` says it stopped; each row a card with `margin`, `upset`, `comments`, `frame` · the card with each seat's `rating_change`, and a signed replay URL; a trial only once its candidate is public, else 404 |
| GET | `/v1/games/{game}/seasons/{slug}/playing` | Public | `{playing}`: matches on a board right now, trials excluded; uncached, because it moves at every claim |
| GET | `/v1/matches/{id}/frame` | Public | `{id, map, turn, seats, frame}`: the last frame of a public match, else 404; `Cache-Control: immutable` once a frame exists, a minute until then |
| GET | `/v1/matches/{id}/related` | Public | Twelve cards: these models' latest in turns (winner's model first), three on the board, then the season's latest |
| POST | `/v1/events` | Public | `{event, match, via}`: 204 always; 400 `event_invalid`, `via_invalid`, `match_invalid`; a private or unknown match writes nothing |
| GET | `/v1/profiles/{username}` | Public | A competitor's public versions by game and season, `bio`, `medals`, each model's `latest_match` |
| GET | `/v1/profiles/{username}/comments` | Public | The author's live comments, newest first, each with its host and `link`; `cursor` |
| GET | `/v1/threads` | Public | `match` or `model`, `cursor`: twenty top-level comments with their replies, the live count, the lock; a match nobody may see 404s |
| POST | `/v1/threads/comments` | Session | `{match \| model, parent?, body}` → 201, `held` on a listed word or a link; 400 `body_invalid`, 403 `commenting_off`, 404 `unknown_host`/`unknown_parent`, 409 `thread_locked`, 429 `too_fast`/`daily_limit` with `retry_after` and `Retry-After` |
| DELETE | `/v1/comments/{id}` | Session | Your own comment → `deleted` (a placeholder while replies hang beneath it); 204 |
| POST | `/v1/comments/{id}/reports` | Session | `{reason?, words?}`, one per reader per comment; 201; 409 `own_comment` |
| GET | `/v1/stories` | Public | `kind` = all, team or model; `cursor`, `limit` ≤ 60: published posts and featured stories as cards, newest first |
| GET | `/v1/posts/{slug}` | Public | One published post |
| GET | `/v1/announcements` | Public | Live announcements, newest first |
| POST · GET | `/v1/runner-keys` | Admin | Mint a key (the only response that carries it) · every key, each with `owner`, `mine` and `season` |
| DELETE | `/v1/runner-keys/{id}` | Admin | Revoke any key, a season admin's included, and every runner started from it |
| GET · DELETE | `/v1/runners` · `/v1/runners/{id}` | Admin | The fleet · stop one machine, key untouched |
| GET | `/v1/admin/users` | Admin | Every admin, and up to 50 competitors matching `?q=` (handle or display name), each with held, reported and removed comment counts and the commenting switch |
| GET · PATCH | `/v1/admin/users/{id}` | Admin | A user's desk, by id or handle: account, counts, sign-ins, models, comments, reports, audit · `{"role": "admin" \| "competitor"}`; 409 `not_yourself`, `not_a_person` |
| PATCH | `/v1/admin/users/{id}/commenting` | Admin | `{off: day\|week\|month\|forever, reason}` or `{off: null}` |
| GET | `/v1/admin/audit` | Admin | `admin` (handle), `action` (prefix), `q`, `cursor`; newest first |
| GET | `/v1/admin/events` | Admin | Per day since `since`: visits, opened (with `opened_via`), finished |
| GET | `/v1/admin/comments` | Admin | `view=held\|reported\|all`, `q` (`@handle` or text), `cursor` (a keyset for `all`, an offset for `held` and `reported`); whole rows with reports; tab counts |
| POST | `/v1/admin/comments/decide` | Admin | `{ids, action: approve\|remove\|restore, reason?}`, ≤ 100 ids, an audit line each |
| PATCH | `/v1/admin/threads` | Admin | `{thread \| match \| model, locked, reason?}`; makes a host's thread when it has none |
| GET · POST | `/v1/admin/words` | Admin | The word list · `{word}`; 400 `word_invalid`, 409 `word_listed` |
| DELETE | `/v1/admin/words/{id}` | Admin | Takes a word off the list; 204 |
| GET · POST | `/v1/admin/posts` | Admin | Drafts and published · `{slug, title, body}` starts a draft; 409 `slug_taken` |
| GET · PATCH | `/v1/admin/posts/{id}` | Admin | One post, draft included · `{slug?, title?, body?, published?}` saves, publishes or unpublishes |
| GET | `/v1/admin/stories` | Admin | Every story with its state; a held edit comes whole |
| PATCH | `/v1/admin/stories/{model_id}` | Admin | `{action, reason?}`: feature, unfeature, approve, reject, remove or restore; 409 `story_state` |
| GET · POST | `/v1/admin/announcements` | Admin | Live first, then past · `{kind, body, link?, dismissable?, ends_at?}` publishes at once |
| PATCH | `/v1/admin/announcements/{id}` | Admin | `{"disabled": true}` |
| POST | `/v1/admin/notify/count` | Admin | `{audience}` → `audience`, `recipients` |
| GET · POST | `/v1/admin/notify` | Admin | The sent log with `recipients` and `read` · `{subject, link?, audience}` sends now; 400 `notify_invalid`, 422 `no_recipients`. An audience is a union of `{"everyone": true}`, `{game, season, class?}`, `{models: [...]}`, `{handles: [...]}`; baselines never |
| GET · POST · PATCH | `/v1/admin/picks` | Admin | Live picks as the public cards with `pick_id`, `position`, `pinned_by`, `pinned_at` · `{match_id}` pins (404 for an unknown id, 422 `match_not_public`, 409 `already_pinned`) · `{ids}` reorders the whole list (409 `order_incomplete`) |
| DELETE | `/v1/admin/picks/{id}` | Admin | Unpins |
| POST | `/v1/runner/token` | Public, address-limited | Key → ten-minute token; the runner self-registers on `(key, label)` and reports `max_in_flight`, `ops_budget`, `match_timeout_ms` and `seat_concurrency`; 409 when its `ops_budget` disagrees with a live season |
| POST | `/v1/runner/claim` | Runner | One match and its execution contract, or `200 {"idle": true}` |
| POST | `/v1/runner/matches/{id}/start` · `/renew` · `/release` | Runner | claimed → running · extend the lease (`{applied, lease_expires_at}`) · requeue, spending a refusal |
| POST | `/v1/runner/matches/{id}/replay-url` | Runner | Presigned PUT for `replays/<match>/<claim_token>.json` |
| POST | `/v1/runner/matches/{id}/finish` | Runner | Result, and optionally the last `frame` (an object up to 64 KB, stored opaque) · `200 {applied: true}` · `200 {applied: false}` duplicate · `409` claim lost |
| GET | `/v1/runner/roster` | Runner | Every `verified` or `active` version a runner must be able to play |
| POST | `/v1/runner/admissions/claim` | Runner | `{orion_version}` → one prepared submission (registration, key, digest, budget, reference observations) and its claim, or `200 {"idle": true}`; 409 `orion_version_differs` |
| POST | `/v1/runner/admissions/{id}/report` | Runner | `{claim_token, admission, stats, probe}` (`probe.round_trip` `{checked, failed}` for a model with memory) → `200 {applied: true}` · `200 {applied: false}` duplicate · `409` claim lost |

Every admin write inserts its `audit_log` line in the same statement. A season's close freezes its
podium into `season_podium` (one place per owner, no baselines) and sends each placed owner a
`medal`.

`/v1/admin-check` exists for nginx `auth_request` (web puts the Orion console behind it): 2xx allows,
401 sends the caller to sign in, 403 refuses. Keep the 401/403 split. The port also serves Orion's
admin API, `/health`, `/readyz` and `/metrics`. Only `/v1/` may be proxied.

## Clocks

Authored as `channels/soma-clock-*.json` and `workflows/soma-clock-*-run.json`, with their
statements in `sql/soma-clock-*.sql`. Each is a `forbid` singleton on its own key with the `latest` misfire policy;
the singleton buys order, and the SQL fences buy correctness.

| Channel | Every | Timeout | Does | Fence |
|---|---|---|---|---|
| `soma-clock-admit` | 20 s | 600 s | Expire, claim `testing` versions, prepare each for an admitting runner or judge its report, write one verdict each | per-row `admit_token` claim |
| `soma-clock-pair` | 15 s | 60 s | Read demand (a round's quota, else the settling rule, plus the idle fill into free lanes), fill the room with the plugin's plan, insert trials first, stamp each match's round; halts quietly while no board is in play | roster epoch, checked `FOR SHARE` per insert |
| `soma-clock-count` | 10 s | 60 s | Start each round that is due (the reset, and the old round's queue cancelled `ROUND_ENDED`); fold finished matches in finish order (moving each board's and season's counts), decide trials, promote | run fence on `clocks.count` |
| `soma-clock-withdraw` | 60 s | 30 s | Cancel queue rows that can no longer be played; keep a season played in rounds one reset ahead; post each round's countdown and tell its entrants; close each live season whose finals are done, that settled or was asked to; snapshot every live season's Open ladder once an hour | none: idempotent |
| `soma-clock-reap-run` | 5 s | 10 s | Return lapsed leases to `pending`; the third lapse fails the row | none: idempotent |

**Version life cycle:** `testing` → admit → `verified` → trial (count) → `active` → `superseded`,
or `rejected` at either step.

**Admission runs no model here.** `soma-clock-admit` walks a submission twice. *Prepare* checks what needs no
model (both objects are in the bucket, the manifest hashes to its declaration, the registration rebuilt
from it field by field) and queues one `admissions` row. A row exists from the POST that signed the
uploads, so for `upload_window_s` (30 minutes from that POST) a missing file is a competitor
still uploading: the clock holds the item and looks again when the hold lapses, and only past that
window is it `ARTIFACT_MISSING` or `MANIFEST_MISSING`. Both upload routes sign their PUTs for what is
left of the same window, and a re-POST past it is `version_in_flight`, so no URL outlives it. An
**admitting runner** (kalam,
`RUNNER_ROLE=admit`) claims it through the gate, registers it on its own node, lets Orion admit it,
plays it over the first `admit_observations` of the game's reference observations, deletes it and
reports. *Decide* reads the report through `admission_facts()`, measures S' from the clock's own HEAD
and the runner's bytes, picks the class, prices the declared memory against it and writes the
verdict. A report that decided nothing (the
runner could not fetch, ran out of time, or measured the probe over `max_probe_ms`) goes back to the
queue with its attempt spent; a submission waiting for a runner spends none. Nothing is admitted
while no admitting runner is up, and `admitters_up(season)` -- the admission claim's own reach
predicate, so the two cannot disagree -- is what says so: it is on `/v1/status` (`admitters`,
platform-wide) and on each season's runner-keys document, which a season desk draws its alarm from.
A machine counts when it reported an admission lane (`runners.admits`, from kalam's `admit_slots`)
and was last seen inside ninety seconds. A baseline goes `testing` → `disabled` ⇄ `active`. **Plugins:**
`tb.rating.trueskill` is the TrueSkill update on the one rated ladder (Open), pure; `tb.pairing.pair` picks opponents and
boards, pure and seeded by the occurrence id. `tb.ants` is the engine, loaded so a map upload can be
judged by `worldgen`.

| Table | Written by |
|---|---|
| `users`, `sessions` | sign-in, `PATCH /v1/me`, session routes; roles by hand |
| `games` | `bootstrap` |
| `seasons`, `season_maps`, `season_map_events`, `baseline_events` | admin and season-admin routes; withdraw closes each settled season; `bootstrap` re-stamps every live season's engine on a patch; count's fold moves the match counts |
| `models`, `model_versions` | entry and submission routes insert; admit and count decide; baseline flips |
| `matches`, `match_seats` | pair inserts; Kalam claims, plays and finishes (through the gate), which lists an ordinary match; count rates, and a trial's pass lists it; withdraw, promotion and disables cancel |
| `ladder_snapshots` | withdraw, once an hour per live season |
| `ratings`, `rating_events` | count; a baseline's first enable seeds its Open rating at the prior |
| `clocks` | count's fence; every roster change bumps `roster` |
| `season_admins`, `season_participants` | admin assigns/removes admins; season admins add/remove participants; `season_admits`/`season_visible` read them |
| `runner_keys`, `runners` | admin routes and the season runner-keys route (a key may bind to one season, `runner_keys.season_id`); the token exchange upserts runners |
| `notifications`, `notification_settings` | the writer after each decision; the settings route; Notify |
| `threads`, `comments`, `comment_reports`, `comment_words` | the comment, report and admin desk routes; no clock |
| `model_stories`, `posts`, `announcements`, `picks`, `notify_sends` | the story route and the admin desks |
| `audit_log` | every admin write, inside its own statement |
| `watch_events` | `POST /v1/events` |
| `season_podium` | withdraw's close |

## Development

| Command | What it does | Needs |
|---|---|---|
| `./scripts/check-defs.sh` | `orion-server clippy` (which runs lint's gate first), `fmt --check`, `check-names.sh`, `check-tests.sh`, and `clippy -c docker/soma.toml.tmpl` for the three rules that need the serving config (all `--deny-warnings`) | `orion-server` in `shared/package.json`'s range |
| `./scripts/check-names.sh` | The ids, the three tags, the `sql/` filenames and every `var://` name against `[vars]`. Derives each channel's surface from its protocol, route and role guard, and fails if the tag or the id's second segment disagrees | nothing; it reads the set |
| `./scripts/check-tests.sh` | Every `tests/*.case.json` through `orion-server test`: the branch each route and clock takes, the answer it gives and the calls it makes, with stubbed connectors and the package's own plugins. `tests/with-ants/` is a second run and needs `TB_ANTS_PLUGIN_DIR` (else a kalam or ants checkout beside this one), or it is skipped and says so | nothing; `check-defs.sh` runs it |
| `cargo test --manifest-path plugins/Cargo.toml` | Rating and pairing host tests | stable Rust |
| `plugins/build.sh tb-rating` (or `tb-pairing`) | Tests, then the wasm component and `plugin.json` beside the source (gitignored) | `wasm32-unknown-unknown`, `wasm-tools`, Python 3.11+ |
| `./scripts/check-sql.sh` | `orion-server sql check`: prepare every shipped statement against a scratch schema built from `migrations/`, each as its connector's role, and plan it to prove that role's grants | docker, or `SQLCHECK_DATABASE` |
| `./scripts/verify/run.sh` | What the statements mean: the scenario walk, both fence races, that the migrations seed nothing an admin makes, the `runner_gate` grants. It reads each shipped statement out of the workflow that ships it, so there is no copy to drift | a postgres container (`DB_CONTAINER`) |
| `./scripts/smoke.sh` | Every route's status code with a minted session, against the newest season (create one first); an admin handle adds a runner-key → token → claim round trip | the running stack, package loaded |
| `./scripts/load-package.sh [--prune]` | Compile a working copy and `package apply` it into a running node; `--prune` retires what the applied version carried and this one does not. A node applies its own package at boot without this | `orion-server`, the admin API |
| `docker build -t tinybrains/soma:dev .` | The node image | Docker |

Script env: `DB_CONTAINER` (default `tinybrains-db-1`), `DB_USER`, `BASE`,
`SMOKE_HANDLE`, `SOMA_ENV_FILE` (smoke; default `../web/.env`), `ORION_ADMIN`,
`ORION_ADMIN_API_KEY` (load-package), `TB_ANTS_PLUGIN_DIR` (check-tests).

**The cutover** (`scripts/cutover/`) is not a check but this release's one-time migration of an
existing database, and its order is the whole of it: `cutover.sh` builds the new schema beside the
old one, copies every row across, swaps the names and commits or rolls back whole, keeping the old
schema as `legacy`; `retire.sh` archives, in Orion's state, the definitions this release renamed;
`backfill-frames.sh` fills in the last frame of every older match once the new node serves. The
first two run **with every node stopped**, and `retire.sh` before the new node boots: a boot apply
never prunes, and Orion refuses a channel on a route another active channel still claims, so a
renamed channel stops the node in a loop — and once a boot apply has succeeded, `--prune` finds
nothing left to remove. Both scripts dry-run until `--commit`.

## Configuration

Environment is read by [`docker/entrypoint.sh`](docker/entrypoint.sh), the instance template
[`docker/soma.toml.tmpl`](docker/soma.toml.tmpl), the connectors and `scripts/load-package.sh`. Web's
compose file sets every one of them for the local stack.

| Variable | Default | Purpose |
|---|---|---|
| `SOMA_DB_URL` | required | Platform database as its owner (`soma-db`: routes and clocks) |
| `RUNNER_GATE_DB_URL` | required | Same database as `runner_gate` (`soma-db-gate`: the gate's match statements) |
| `ORION_STATE_DB_URL` | required | Orion's own state, database `orion_state` |
| `REDIS_URL` | required | Cluster state |
| `SOMA_DB_MAX_CONNECTIONS`, `SOMA_GATE_DB_MAX_CONNECTIONS` | 8, 4 | `soma-db` and `soma-db-gate` pool sizes |
| `SOMA_DB_CONNECT_TIMEOUT_MS`, `SOMA_GATE_DB_CONNECT_TIMEOUT_MS` | 5000 | Dial deadline **and** the pool wait: sqlx takes it as `acquire_timeout` |
| `SOMA_STATE_DB_MAX_CONNECTIONS`, `SOMA_STATE_DB_MIN_CONNECTIONS` | 15, 2 | Orion's own state pool (`[storage]`) |
| `SOMA_STATE_DB_ACQUIRE_TIMEOUT_SECS` | `10` | How long a request waits for a state connection |
| `SOMA_CRON_WORKERS` | `4` | How many clocks may run at once; never below the number that can be due together |
| `ORION_ADMIN_KEY` | required | Admin API key (`[admin_auth]`). Required by name: an unset or empty value stops the boot saying so |
| `TB_TRUST_PUBLIC_KEY` | required | Ed25519 key plugin signatures must verify under |
| `SOMA_SESSION_SECRET` | required | HS256 for session cookies and OAuth state, at least 32 bytes |
| `RUNNER_TOKEN_SECRET` | required | HS256 for runner tokens; a different key from the session one |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | required | The OAuth App |
| `R2_ENDPOINT`, `R2_BUCKET` | required | Replay bucket, at the address a **browser** fetches a replay from (presigned GET only) |
| `R2_ACCESS_KEY`, `R2_SECRET_KEY` | required | Object-store credentials for both buckets |
| `MODELS_BUCKET` | required | Models bucket |
| `MODELS_ENDPOINT` | required | Models bucket as **the node** dials it: HEAD, manifest GET |
| `MODELS_PUBLIC_ENDPOINT` | required | Models bucket as **a competitor** reaches it; submission PUTs are signed for it |
| `RUNNER_BLOB_ENDPOINT` | required | Object store as **a runner** dials it; replay PUTs are signed for it and it must equal the runner's `kalam-blobs-put` base |
| `APP_URL` | `http://localhost:5173/` | Where sign-in returns; an allowed `?next=` origin |
| `OAUTH_REDIRECT_URI` | `http://localhost:5173/v1/auth/{provider}/callback` | A `{provider}` template, filled per provider and registered with each; https except on loopback |
| `CONSOLE_URL` | `http://localhost:8081` | The Orion console, the second allowed `?next=` origin |
| `SOMA_COOKIE_SECURE` | `1` | `0` only for a plain-http stack |
| `SOMA_TRUSTED_PROXIES` | the RFC1918 ranges | TOML array of proxies whose `X-Forwarded-For` is believed |
| `SOMA_ADMIN_IDS` | empty | `provider:subject` pairs, comma-separated (a GitHub id is `github:<id>`), made admins at every sign-in; the node refuses to start on anything else |
| `ORION_CLUSTER_ENABLED`, `ORION_INSTANCE_ID` | `true`, empty | Cluster mode; a stable id per node |
| `ORION_VERSION` | `1.11.1` | Recorded on every verdict and match as `orion_version` |
| `ORION_SHUTDOWN_DRAIN_SECS`, `ORION_SHUTDOWN_FORCE_SECS`, `ORION_CRON_SHUTDOWN_SECS` | 30, 30, 60 | Shutdown bounds |
| `SOMA_CRON_CLAIM_LEASE_SECS` | `60` | How long a dead node's clock runs hold their slots, and how long a state-database outage a running clock survives (the lease minus one 15 s heartbeat) |
| `PLUGIN_SIG_DIR` | none | `<component>.sig` files for tb.rating, tb.pairing and tb.ants |
| `SOMA_ALLOW_PRIVATE_URLS` | `false` | `[vars] allow_private_urls`, which every connector but `soma-cache` reads: compose service names resolve to private addresses |
| `SOMA_CACHE_URL` | *(required)* | `soma-cache`'s Redis, the response cache for the anonymous reads. An absent `env://` skips the connector |
| `SOMA_IDLE_MARKER_TTL_SECS` | `30` | How long a runner's idle marker lives: a claim that found nothing answers idle from `soma-cache` until a write bumps `gen:work` or this passes |
| `SOMA_CACHE_ENTRY_TTL_SECS` | `600` | The ceiling on any other entry a workflow keeps on `soma-cache` |
| `SOMA_SESSION_CACHE_TTL_SECS` | `300` | How long `/v1/me`'s session entry lives on `soma-cache`; sign-out deletes it and every revocation invalidates it before that |
| `SOMA_HOT_CACHE_TTL_SECS`, `SOMA_SEASON_CACHE_TTL_SECS` | 600, 600 | The ceiling on how long an anonymous read is served from `soma-cache`; a write invalidates the namespaces it touched before that |
| `SOMA_RATE_*_RPS`, `SOMA_RATE_*_BURST` | as shipped | One pair per rate-limit family (`public`, `session`, `per_user_read`, `per_user_write`, `per_admin_board`, `runner`, `runner_token`, `per_runner`, `signin`); `docker/soma.toml.tmpl` lists them |
| `GITHUB_USERINFO_URL` | `https://api.github.com/user` | GitHub's userinfo endpoint; Orion fetches it with the access token to build the sign-in identity |
| `SOMA_AUTH_PROVIDERS` | `[{"slug":"github","label":"GitHub"}]` | JSON array of the sign-in buttons `GET /v1/auth/providers` serves; keep in step with the providers the channel serves |
| `SOMA_ARTIFACT` | `/var/lib/orion/soma.package.json` | Where `serve` compiles the package to, and what `[packages] apply` reads |
| `SOMA_ADMIN_DB_URL` | bootstrap, required | The maintenance database (`.../postgres`), for `CREATE DATABASE orion_state` |
| `RUNNER_GATE_DB_PASSWORD` | bootstrap; required | The runner gate role's password; the migration creates the role with none |
| `ENGINE_RELEASE` | bootstrap, `0` | `1` declares the engine as a release instead of a patch |
| `GAME` | `ants` | The game bootstrap registers |

**Node sizing.** Every pool, rate limit and cache TTL is a `[vars]` entry the definitions read as
`var://`, not a literal in the package: a var keeps its declared TYPE, which an `env://` (always a
string) cannot. **The Postgres budget is `SOMA_DB_MAX_CONNECTIONS + SOMA_GATE_DB_MAX_CONNECTIONS`
against `soma`, plus `SOMA_STATE_DB_MAX_CONNECTIONS` against `orion_state` — 27 as shipped**, plus a
transient `psql` or two while `bootstrap` runs. Shrink the pools before the cron workers: five clocks
are declared and `soma-clock-admit` holds a worker for as long as its 600 s timeout, so fewer workers
than clocks that can be due together is an idle ladder on a node whose `/readyz` says ok. The
response cache takes load off the pools and the node at once: an anonymous read is served from
`soma-cache` until a write invalidates it, and the TTLs are only the ceiling.
`scripts/check-names.sh` refuses a `var://` name `[vars]` does not declare — Orion's own rule reads
workflow logic and not a connector's config, so that one is checked here.

**Build args:** `ANTS_RELEASE` (empty is the latest ants release; the cartridge, reference set,
engine digest and component come from it), `ORION_VERSION` (1.11.1), `RUST_VERSION`,
`WASM_TOOLS_VERSION`, `CURL_VERSION`, `DEBIAN_VERSION`. **Policy numbers** (pairing, rating,
admission, runner contract) are `[vars]` in `docker/soma.toml.tmpl`, and most can be overridden per
season through its `rules` document (`season_rule_spec()` in
[`migrations/0001_init.sql`](migrations/0001_init.sql) is the list).

## Operating a season

1. **Create it** (`POST /v1/games/{game}/seasons` or the admin page). The name gives the slug, and
   neither ever changes. **Seasons overlap** (N30): a game may run any number of live seasons at
   once, so a create is never refused for another season being live. It sets `visibility`
   (public|private), `entry` (open|restricted; private forces restricted), the `fleet` policy and
   the `providers` a season allows, and it pins `games.active_engine_digest`. Window, rules and
   classes stay editable only until it opens.
2. **Check its boards** with `tinybrains maps check <board.json>...`, which runs the same envelope
   and `worldgen` checks as the upload.
3. **Upload boards and baselines.** Both land disabled. Each map file is one `POST .../maps`;
   `PATCH` `{"enabled": true}` puts it in play and re-runs the engine check under this node's engine
   (refused `engine_mismatch` when the node and the season disagree). A baseline is
   `POST .../baselines` plus two uploads; the admit clock admits it like a submission and lands it
   `disabled`; enabling seeds its ratings at the prior. The season's admin page does all of this.
   **Nothing pairs** until a board is enabled, and no trial pairs until a baseline is enabled.
4. **While it runs**, boards and baselines can be enabled and disabled. A disable cancels the
   pending matches on it, while claimed and running ones finish and count. **Rounds** (`rules.rounds`)
   put a reset in `season_rounds` every `days` from the open; count applies each at its start (every
   active sigma raised to `sigma_floor`, mu drawn `mu_shrink` toward the season mean, the old round's
   queue cancelled `ROUND_ENDED`), pair gives every active version the round's `games`, least-played
   first, and the withdraw clock posts the countdown `warn_minutes` before. An admin can add, move or
   cancel a reset on the season's Rounds and finals page. The **idle fill** (`seasons.fill`, live)
   queues matches into the free lanes of the runners that may play the season, toward `fill.games`
   in the window; it reads the fleet's capacity to size demand and never the reverse.
4b. **Carry a season into the next** (Q7). A new season starts with no boards, baselines,
   participants or versions. `POST .../maps/import {from}` copies a season's boards into it, switched
   off (switching one on re-runs the engine's check); `POST .../baselines/import {from}` makes each
   admitted baseline a new version over the same bytes (`bytes_of`), admitted again under the new
   season's rules and landing switched off. A competitor carries an entry over with
   `POST /v1/submissions/reenter {game, model, season, from}`: the entry's standing, same bytes, a
   fresh `testing` version that admission and a trial judge again. Nothing is uploaded or copied in
   the bucket.
5. **Close it.** With `closure.policy` `finals`, the season waits after its window for an admin to
   start the **finals** (`POST .../rounds` `{kind: "finals", games, ...}`, refused while the window is
   open or a submission is still being admitted): a reset, then exactly `games` matches for every
   entry (a wall in the plugin; baselines fill seats and are never waited for), and the close once
   every entry has played them and nothing is in flight. Once scheduled, the finals decide the close
   whatever the policy. Otherwise the withdraw clock closes a season once its window has closed and
   every version has settled (`settle`, the default), after `settle_grace_days` (`deadline`), or only
   on request (`admin`). `POST .../close` records a request, which wins over all of these (it is how
   finals that cannot finish are ended); within the minute the close rejects versions still waiting
   (`SEASON_CLOSED`), cancels the queue and any round still waiting, and lets running matches count.
6. **Change the engine.** `bootstrap` from an image on a new ants release declares a **patch** by
   default: the game and every season not yet closed (live or scheduled) take the new digest,
   pending rows are re-stamped and the roster epoch bumps. `ENGINE_RELEASE=1` declares a **release**,
   refused while any season is unclosed: a rules change waits for the next season. A runner on any other digest claims nothing.
7. **After the close**, push the season's boards and recipes from `tinybrains/maps/` to the backup
   repository. They are in no repository or release while the season runs.

Admins are `users.role = 'admin'`. The first is the deployment's: `SOMA_ADMIN_IDS` lists
`provider:subject` pairs (a GitHub id is `github:<id>`; web's `scripts/setup/admin-user.sh <login>`
looks a GitHub id up), and a listed account is made an admin each time it signs in. The subject, never
a login: a provider frees a renamed login for anyone to register. Every other admin is made and unmade
by an admin on the Users admin page (`PATCH /v1/admin/users/{id}`), which refuses a caller's own role
so there is always one left, and tells the account and every other admin. A demotion is immediate; a
listed account is restored by its next sign-in, so removing someone for good means removing their
`provider:subject` too.

## Production requirements

- **The models bucket needs a CORS rule** allowing `PUT` from the site's origin: `/submit` uploads
  from the browser. MinIO answers preflights by default, and R2 and S3 do not. Verify from a browser,
  because `curl` sends no `Origin`.
- **`models/*` public-read, replays private**, and a lifecycle rule expiring `replays/` by age.
- **One bucket for uploads and nodes.** A node reading a different bucket from the one Soma signed
  the upload for rejects every submission `ARTIFACT_MISSING`.
- **Cluster mode whenever N > 1**: two nodes on two state databases are two schedulers, so each
  clock runs twice (fenced, but not once). Channel rate limits then live on Redis and are fleet-wide.
  `[rate_limit]` limits and `max_concurrent_per_node` stay per node.
- **Alert** on `/health` `config_propagation = degraded` and `orion_errors_total{reason="config_epoch_bump"}`.
- **Give the response cache its own Redis** (`SOMA_CACHE_URL`), with `maxmemory-policy
  volatile-lru`. Sharing one with cluster state means no eviction policy can trim the cache without
  evicting the clocks' coordination, and `allkeys-lru` could evict a namespace counter
  (`orion:rc:ns:*`, no TTL): an evicted counter reads as version 0 and serves again an entry stored
  before the namespace was first bumped. Entries carry TTLs; counters do not; `volatile-lru` takes
  only entries.
- **TLS**: `SOMA_COOKIE_SECURE=1`, and an https `OAUTH_REDIRECT_URI` (Orion refuses http off
  loopback).
- **Never expose port 8080 beyond the proxy.** It carries the admin API and `/metrics`.
  `admin_auth` is on, and `/health` detail needs the key.
- **An admitting runner, somewhere.** Soma runs no model, so a submission waits in `testing` until
  a kalam runner with `RUNNER_ROLE=admit` claims it (`--profile admit` in kalam's compose files). One
  per deployment is enough; run it on the Orion `orion_version` names, or the claim refuses it.
- **Non-empty trust keys** and plugins signed by web's `scripts/setup/sign-plugins.sh` for every new
  image, or the boot apply stops the node on a quarantined channel.
- **Narrow `SOMA_TRUSTED_PROXIES`** to the proxy actually in front. Empty, every browser shares one
  rate-limit bucket. Too wide, anyone inside the range can claim any address.
- **The role password** (`RUNNER_GATE_DB_PASSWORD`) comes from a secret store.
- **`SOMA_ADMIN_IDS`** holds the owner's `provider:subject` (e.g. `github:<id>`) and nothing more.
  Empty, nobody can reach an admin page; every other admin is granted on the Users page.
- **Scale runners on demand, never on queue depth.** Pair caps the queue at `pair_depth_target`, so
  a scaler reading depth caps the fleet at `pair_depth_target` over a runner's lanes and looks
  correct doing it. Demand is what pair itself reads (`sql/soma-clock-pair-run-demand.sql`): the
  seats the roster wants, which LEAD the queue -- a runner is wanted before the rows it will claim
  exist. The fleet is about `(demand + outstanding) / lanes`, where lanes is a runner's
  `RUNNER_CRON_WORKERS`, plus one runner while the oldest `pending` row has waited too long. Count
  only the live season's rows on its own `engine_digest`, or a rolling engine change asks for
  runners to drain rows nothing will claim.
- **Timeouts:** a channel's `timeout_ms` bounds a whole run (admit: 600 s for up to `admit_batch`
  submissions), `admit_timeout_s` (180 s) bounds this clock's hold on one submission before another
  run may re-claim it, and `admit_lease_s` (600 s) bounds an admitting runner's. `upload_window_s`
  (1800 s) is none of those: it is how long a submission may still be arriving, counted from its
  POST, and the two upload routes sign their PUTs for what is left of it.

## Releasing

```sh
gh workflow run release.yml               # rehearsal: both platforms built and diffed, nothing pushed
git tag v0.2.0 && git push origin v0.2.0  # from main: ghcr.io/tiny-brains/soma:0.2.0, :0.2, :latest
```

The workflow builds on arm64, and the plugins, cartridge and orion-server download are built once
on the build platform, so the amd64 and arm64 images carry identical components and one signature
verifies on both. The ants release is the repository variable `ANTS_RELEASE`, or the latest, and
is recorded as the label `dev.tinybrains.ants.release`. **Under a live season, pin
`ANTS_RELEASE`**: a Soma and a runner built from different releases are two engines. A tag is never
re-cut. After a new image, re-sign the plugins.

## Layout

```text
Dockerfile                  the node image: plugins, the ants cartridge and component, orion-server, the package
docker/entrypoint.sh        `serve` and `bootstrap`
docker/soma.toml.tmpl       the instance config, cluster mode, and every [vars] policy number
.github/workflows/release.yml  a v* tag publishes the image for amd64 and arm64
channels/soma-*.json        routes: method, path, auth, rate limits, cache
workflows/soma-*.json       their task lists and inline SQL; each `description` carries the route's reasoning
channels/soma-clock-*.json   the five clocks; their task lists are workflows/soma-clock-*-run.json
connectors/                 soma-db, soma-db-gate, soma-cache, soma-blobs (replay GET),
                            soma-blobs-gate (replay PUT), soma-models (public: upload PUT),
                            soma-models-internal (HEAD + GET), soma-models-http
shared/soma.json            constants and fragments the set references with $from and use
plugins/                    tb-rating and tb-pairing (one cargo workspace) and build.sh
migrations/0001_init.sql    tables, constraints, shared functions, roles and grants
migrations/0002_sessions.sql  sessions, live_sessions, notifications, notification_settings
sql/                        every statement over ~240 characters, one file each; the workflows
                            name them with {"$sql": "../sql/<name>.sql"} and compile inlines them
scripts/load-package.sh     compile and apply a working copy into a running node; --prune retires
                            what a version dropped. A node's own [packages] apply does the boot
scripts/check-defs.sh       no-stack gate
scripts/check-names.sh      the ids, the tags and the sql/ filenames; run by check-defs.sh
scripts/check-sql.sh        orion-server sql check, as each connector's role
scripts/smoke.sh            every route, against a running stack
scripts/verify/             run.sh (reads the shipped statements), statements.sql (only what does
                            NOT ship), scenario.sql, the race files
```

## Invariants

- **Only count writes a rating**, and every ladder write re-reads count's run fence `FOR SHARE`.
  Routes and clocks share the owner role, so this is a review boundary, not a grant.
- **Pair's insert derives everything and trusts nothing**: it checks the roster epoch, takes the
  seat count from an enabled board of the live season, and refuses self-pairing unless the season
  allows it. A stale plan inserts nothing.
- **Admission writes only under its `admit_token`**, and an attempt is a runner's claim. A
  submission waiting for a runner, or for this clock over a fault of its own, spends nothing; a
  report that decided nothing keeps the attempt its claim spent, so one that fails the same way on
  every runner expires `TIMED_OUT` instead of retrying every tick. The one exception is a probe
  over `models.max_probe_ms` on every attempt (`admissions.slow_probes`), which is the model's and
  expires `PROBE_TOO_SLOW`, with the last median kept as the version's `infer_us`.
- **A runner executes admission and never decides it.** The registration is rebuilt here, the report
  is typed by `admission_facts()` before anything binds it, and `runner_gate` can write an
  admission's claim and report and no verdict column.
- **Trials feed no ladder**, and a loss alone never rejects a candidate.
- **A trial is live until count decides it**, `finished` included, in pair's read exactly as in
  `matches_one_live_trial_uniq`. A pair run that offered a second trial would die on the index.
- **A refusal is the fleet's, never the candidate's.** The gate fails a row `MODEL_UNAVAILABLE` only
  once the ceiling is spent and the refusals have been going on longer than `refusal_grace_secs`,
  counted from the row's own first refusal (`matches.first_refused_at`) and not from when it was
  paired -- so a fleet that comes up cold against an old queue gets its allowance whatever the rows'
  age, which is what replacing a fleet with work queued looks like. A refused trial spends no
  repair: it has a ceiling of its own, which rejects `RUNNER_UNAVAILABLE`, never `UNPLAYABLE`.
- **A shape many routes return is defined once, in the migration** (`season_json`, `season_state`,
  `current_season`, `model_phase`, `model_ratings`, `ladder_field`, `match_seat_rows`, the
  `season_admits*` predicates). A second copy is two pages that disagree.
- **Weight classes are the season's and strictly ascending.** Admission takes the first class a
  size fits.
- **A class's memory is a cap, priced from the manifest.** Each class may carry
  `memory_flat_bytes` (0 to 262,144) and `memory_cell_bytes` (0 to 16), absent meaning 0, and the
  cap on a board is flat + cell × cells. A model remembers by declaring an output named `memory`
  (at most two named axes) or `ant_memory` (at most one); an output with a named axis costs per
  cell. `memory_price()` prices both at the envelope's two ends (the smallest square board and
  `cells_max`), after the class is known, and refuses `MEMORY_NOT_ALLOWED` (a class with 0 and 0),
  `MEMORY_SHAPE` or `MEMORY_TOO_LARGE`; a runner's `probe.round_trip` with a failure is
  `MEMORY_ROUND_TRIP`. All four are final and the competitor's. The version keeps `memory_bytes`,
  the cost on the largest board. Memory is not part of the size a class is chosen by.
- **The schema is two files, rewritten in place, and must pass `check-sql.sh`.**
- **A notification is never part of the statement that decided the thing**, and is keyed so a
  replay inserts once.
- **Revocation is a JOIN inside the statement** (`live_sessions`, `live_runners`), never a guard task
  and never trust in a signed token.
- **The runner routes run as `runner_gate`.** A statement that needs a grant is on the wrong
  connector. Never widen a role for one.
- **The gate's match statements live here, in one copy**, and `verify/run.sh` refuses drift.
- **A gate route's `data.req.*` field names are the contract** with Kalam's runner.
- **`finish` tells a duplicate delivery (200) from a lost claim (409).** Conflating them fails a
  healthy runner.
- **Every definition carries three tags, `[package, surface, domain]`**, in that order --
  `["soma", "gate", "matches"]`. `?tag=` is an EXACT, SINGLE-TAG match with no prefix and no AND,
  and no list page searches names or ids, so the tag filter is the navigation and each tag has to
  be a useful question on its own. The surface is one of `pub`, `user`, `admin`, `gate`, `clock`
  (`conn` on a connector) and is also the id's second segment; `scripts/check-names.sh` DERIVES it
  from the definition and fails if the two disagree. The domain comes from a closed list
  shared with kalam -- web's `scripts/check/configs.sh` compares them.
- **Only caller-invariant routes cache, and every cached route names what it is built from.** The
  cache key has no caller in it, and `cache.namespaces` on the channel is one or more of `season`,
  `ladder`, `matches`, `community` and `announcements`. Every writer of public data, a clock, a
  gate route or an admin or user route, follows its write with the `invalidate` fragment, so an
  entry is served until the data it was built from changes and the TTL is a ceiling, not the
  freshness. The one write that bumps nothing is sign-in's upsert: it refreshes only the cached
  provider login (`identities.login`), which no public read shows, and the handle it seeds once never
  changes -- so there is nothing cached to invalidate.
- **Something private gets its own path** (`/v1/me/matches`), never a parameter on a public route.
- **The board and the terms of play ride the claim.** A runner fetches no board and holds no copy of
  `turn_ms`.

## Known gaps

- Notifications are never pruned. No clock may delete, so pruning needs a writer that is not a clock.
- Push notification settings are stored, but nothing delivers them.
- A refused row is claimed after the fresh rows of its kind, which spreads the refusals; trials
  still come before every ranked match.
- A `failed` match notifies nobody. The gate writes it as `runner_gate`, which must not gain the grant.
- A broken adapter is not rejected as one. An inference that fails outright on the admitting runner
  is reported as a probe that errored, which cannot be told from a runner's own failure, so the
  report goes back to the queue and the version expires `TIMED_OUT` rather than `ADAPTER_INVALID`.
- Admission plays the first `admit_observations` (64) reference observations, each under a fixed
  `admit_infer_ms` that is not sized from the season's `turn_ms`. A model that is legal at play but
  slower than that errors here on every runner and expires.
- A registration the admitting runner's node refuses (400) reads as `ADMISSION_UNREACHABLE`:
  `http_call` writes nothing on a 4xx, so the runner cannot tell a refusal from an outage. It costs
  an attempt each time and expires `TIMED_OUT` rather than being refused with a reason.
- An admitting runner's report is judged, not re-derived. The size is measured here too, but the
  operator set, opset, parameter count and probe tally are the runner's word. A runner key is a
  platform admin's or a season admin's (bound to its season), and a runner key can already report a
  match result.
- A session does not record which provider it was signed in with, so the sessions page cannot say
  (BRD I8). `identities` holds it; `sessions` does not.
- The OAuth callback cannot say which failure happened: `oauth2_login` answers a fixed 401.
- No API tokens for an SDK or CLI.
- `finish` has no `turns <= max_turns` gate (`max_turns` is a season rule, so it needs the claim's coalesce).
- The revalidation sweep is unbuilt: `revalidate_batch` is read by nothing, so a version admitted
  under an older `orion_version` is never re-checked.
- Retention beyond traces is unbuilt: `watch_events`, `audit_log` and `match_frames` grow for ever (a
  frame is a few KB, about 4 MB a day at today's rate). So is the TinyBrain Index (`standings.lambda`
  is accepted and unread).
- Five season rules are accepted by `season_rule_spec()` and read by no statement: `entries.max_per_class`
  (its predicate `season_admits_class_slot()` exists and is called from nowhere -- the admit clock's
  `classify` asks `season_admits_class` and stops), `standings.basis`, `standings.k`, `standings.headline`
  and `graph.size_metric`. A season may set any of them and nothing changes. The spec table guards the
  other direction only -- a rule that is not in it cannot be misspelt into silence -- so closing this
  means either enforcing each rule or giving the table a `reader` column a check can assert against.
- `audit_log_season()` resolves a line's season by slug, and a slug is unique only per game, so a line
  whose `detail` names no `game` is stamped to the newest season of that slug across every game. Every
  season-scoped writer now names one; nothing stops the next one from forgetting, because the trigger
  still falls back to `ORDER BY number DESC` rather than refusing an ambiguous match. The durable fix is
  in the trigger, which is a schema rewrite.
- The `in_flight` list in a submission's refusal detail (`soma-user-shared-submission-why.sql`) counts
  across the game, while the rule it explains (`season_admits_in_flight`) and the preflight both count
  per season, so a 409 can name versions that do not count toward the cap it just refused.
- `sign-uploads` builds its object key from the version id, while `model_versions.artifact_key` is
  `coalesce(bytes_of, id)`. Re-POSTing a submission whose in-flight row came from `/v1/submissions/reenter`
  re-mints presigned PUTs for a key the admit clock never reads; admission still succeeds off the real
  key, and any bytes uploaded to the minted one are unreferenced.
- A model's memory is priced, not measured. `memory_price()` trusts that a named axis binds to the
  board's rows and columns or to the ant count, and nothing at admission compares what a memory
  actually holds with its price.
- The round trip is judged only when the admitting runner reports it. A runner that sends no
  `probe.round_trip` admits a model with memory without one.
- The comment limits (15 s apart, 100 a day) are predicates in the insert, so two posts at the same
  instant can both pass; the per-user write rate is the backstop.
- The admin comment search (`q`) scans: there is no trigram index on `comments.body`.
- A list field sent as a bare string fails Orion's bind (`400 VALIDATION_ERROR`, naming the
  parameter) before the statement can refuse it by name on `comments/decide` (`ids`), `notify` and
  `notify/count` (`audience`), `picks` (`ids`) and `me/notifications/read` (`ids`). The routes that
  promise a named refusal bind the whole request instead (season create, the two imports).
- A malformed uuid, timestamp or cursor in a query string fails its cast and answers 500, not 400.
- The admit and pair clocks still tick against Postgres when idle: admit cannot tell nothing
  waiting from waiting but leased without a read, and pair's demand moves with time.
- A round's reset writes no `rating_events` row (its seq is `matches_played`, and a reset is not a
  match), so a version's history shows the reset only at its next match.
- Finals can stall for an entry nobody is left to play (every other entry at its number, no enabled
  baseline of another owner). The admin page shows it, and a close request ends them.
- The idle fill counts a runner's lanes from its last 90 s of roster heartbeats; a runner that dies
  holds that share of the fill for up to 90 s, and the fill never outruns `pair_depth_target`.
- The leaderboard's `provisional` reads the deploy's `settled_sigma`, not the season's
  `rating.settled_sigma`.
- Retiring an entry (`models.retired_at`) leaves its active version paired: the demand read does not
  filter on it.
- A season admin's notify reaches entrants, pinned participants and the season's admins; an invite
  still waiting for its account's first sign-in reaches nobody until then.
- The season audit (`audit_log.season_id`) is derived by a trigger from each line's slug or target;
  a line written before the column existed, or one naming a season only in free text, has none.
- The finals and the idle fill are a platform admin's; a season admin cannot start or change them.
- An off-site runner must hold a GET key for the models bucket. The fix is an Orion ask, not yet
  filed: a URL-valued artifact reference on the `models` entity.

## License

Apache-2.0: see [LICENSE](LICENSE).
