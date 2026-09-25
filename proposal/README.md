# Soma: the web redesign

This proposal lists what the web redesign (`web/proposal/`) needs from Soma, checked against the
package as it stands. The other repositories keep their share in their own `proposal/`: ants,
kalam and cli. This folder goes when the redesign ships.

The schema changes in one rewrite, and the routes can follow in several Soma releases. `bootstrap`
hashes the migrations byte for byte, so each schema change costs production a rebuild, while a route
costs a package apply. Put every table and column in the first release, even the ones whose routes
come later.

## Decisions

- **Each baseline keeps its own owner**, the `baseline.<slug>` account it has today, and its own
  profile. Pairing refuses two seats of one owner and caps each owner's queue share, so one
  shared owner would stop baselines meeting each other and starve them of matches.
- **Soft delete.** `soma-db` refuses DELETE (`operations.delete: false`), and that stays. Deleting
  a comment, removing one, unpinning a pick, taking a word off the list and disabling an
  announcement each set a state or a timestamp column.
- **Baselines stay off the podium.** The podium, the profile's medals and the champions skip
  baselines and close the ranks up, as the leaderboard's Baselines switch does.
- **One owner, one podium place.** Each ladder's podium takes each owner's best version, then the
  top three owners. A second model of the same owner never takes a second place.
- **No image storage.** Soma stores no picture and no rendered image, and runs no media bucket or
  proxy. The browser draws every board and frame with the viewer and caches what it drew. A card's
  resting picture is the match's last frame, which the runner reports at `finish` and Soma keeps in
  Postgres as opaque JSON beside the match, served by `GET /v1/matches/{id}/frame`. Stories and
  posts are text. Replays stay in their private bucket behind presigned GETs.
- **Bump and restore.** The migrations are rewritten in place, and production is rebuilt from them
  with its data restored (*Production cutover*).

## What exists already

These page needs are met by a route that already answers. Web reads it and Soma does nothing.

| Page need | Where Soma answers it today |
|---|---|
| Players 2, 3 to 4, 5 to 8; Big boards | `GET /v1/matches?players_min=&players_max=` |
| Mine combined with the other filters | `?owner=<handle>` on the same route, trials excluded |
| Your class channel | `?class=` on the same route |
| A version's last three matches (leaderboard row) | `?version=&limit=3` |
| Season strip: matches played, on the ladder, days left | `season_json()`: `matches_played`, `active_versions`, `submissions_close_at` |
| Matches per board | `season_map_json()`: `matches`, finished and rated, trials excluded |
| A queued pairing names its opponents | `GET /v1/me/matches` returns `seats` on pending rows, with `mine` |
| The in-flight list and private matches on your profile | `GET /v1/models`, `GET /v1/me/matches` |
| Baseline profiles | `GET /v1/profiles/baseline.<slug>`, one per baseline |

## Findings

The page proposals assumed these points wrongly or left them out. Each one changes what Soma
builds.

1. **Trials are public today.** `soma-pub-matches-list-query.sql` returns trials to anyone who
   names `?model=` or `?version=`, and `GET /v1/matches/{id}` serves a trial by id. The model
   page's match grid reads `?model=`, so a visitor would see a candidate's trial before the version
   goes public. Return a trial publicly only once its candidate is `active` or `superseded`, when
   it counts as history. The owner reads a trial in progress through `/v1/me/matches`.
2. **Private halves cannot ride a cached route.** An author's held comments and an owner's waiting
   story cannot go in the public routes, which declare `cache` under a key that holds nothing about
   the caller. The first caller's view would reach everyone. They get `/v1/me/...` routes of their
   own, which web merges into the public view.
3. **A replay holds no frames.** `ants/engine/src/replay.rs` stores each turn's actions, so the
   state at the last turn exists only after the browser re-simulates the whole match, which a grid
   of thirty cards cannot afford. The runner holds the final state when the match ends, so it
   sends the last frame in the `finish` body, and Soma stores it as given and never reads inside
   it. The board's static layer is already `season_maps.board`, so the frame carries only what
   moved.
4. **A card grid cannot carry presigned URLs.** `GET /v1/matches/{id}` presigns the replay for an
   hour inside a cached response. Thirty cards would need thirty presigns per workflow run, and
   every cached copy would hold URLs that expire. A card fetches its frame from
   `GET /v1/matches/{id}/frame`, which needs no signing and answers `Cache-Control: public,
   max-age=31536000, immutable` once the match is finished, so the browser keeps it. Hover preview
   fetches `GET /v1/matches/{id}` for its `replay_url` when the pointer rests on a card, so the
   list carries no replay URL.
5. **The hill count is readable.** Every season board's file carries a top-level `hills` array
   of players × H entries, beside the `players`, `rows` and `cols` that `season_map_header()`
   reads today. The header gains `hills`, its length, and the upload checks `Np` and `Hh` against
   the file. It reads a count and no placement, so the board stays the cartridge's.
6. **Sorting by upset or margin needs stored keys.** Computing an upset reads `rating_events` for
   every seat of every candidate match, and the keyset cursor keys on `(played_at, id)` alone.
   Count reads `mu_before` for every seat when it folds a match, so the fold writes
   `matches.upset` and `matches.margin` in the same fenced statement, and each sort gets its own
   cursor.
7. **The rating series goes public, in buckets.** The leaderboard workflow says a version's full
   chain "is not a public route". A season holds a few hundred thousand `rating_events` rows, and
   Rank race wants every version at once, so the series route answers each version's conservative
   rating at N bucket edges over the window: about 3,000 numbers for a 49-version ladder.
8. **`limit` has no ceiling.** Neither the leaderboard nor the matches list clamps it, so
   `limit=100000` runs. Clamp the leaderboard at 200 and the matches list at 60 in SQL.
9. **Push is stored, and nothing delivers it** (README, *Known gaps*). The new notification kinds
   get an app setting and no push setting.
10. **A notification is read or unread.** Soma records `notifications.read_at` and no more, and
    Mark all read sets it for eight rows at once. The Notify log reports "read", not "opened".
11. **The pages need more than the first list named**: a comment count on each card and the Most
    discussed sort; home's "neighbour you lose to most"; the word list applied to version notes,
    which are public text too; and a tag domain for the new routes.
12. **The tag vocabulary has no domain for comments, stories or posts.** `scripts/check-names.sh`
    freezes thirteen. Add `community` for comments, words, stories, posts and picks, in soma and
    kalam together and in web's `configs.sh` comparison. Announcements take `platform`, Notify
    `notifications`, the audit log `users` and watch events `matches`.

## Design

- **Write the podium when a season closes.** The withdraw clock's close inserts `season_podium`
  rows, first to third on each ladder with baselines skipped and one place per owner (each
  owner's best version stands for them), and the final rating. The leaderboard
  podium, the profile's medals and the champions read that one frozen record rather than re-rank
  every closed ladder on each profile view. A `medal` notification goes to each placed owner.
- **Three watch events.** `visit` is one page load, with no match. `opened` carries `via`: tv,
  shelf, grid, next, rail or link. `finished` carries nothing more. "Watch next clicked" is
  `opened` with `via = next`, the same rows tell you whether the TV or the shelves bring more
  viewers, and `opened` over `visit` is matches opened per visit.
- **A rivals route.** Per opposing model this season: played, won and lost, from `match_seats`.
  Home's Your season reads the top loss from it.
- **"Top of the ladder" means two or more seats in the top ten.** An eight-seat board rarely seats
  eight of the top ten, so requiring every seat would fill the channel with 2-player matches.
- **A bio or a version note that trips the word list is refused, not held.** You get a 422 naming
  the rule and rewrite the line. A URL in either is allowed and drawn as plain text. Stories and
  comments keep the hold, since their authors write at length.
- **An announcement links to a site path or an `https://` URL.** Only an admin writes one. Notify
  keeps the site-path rule, since each send becomes a `notifications` row.
- **Commenting off lives on `users`**, as an end time and a reason, and its history lives in
  `audit_log`.
- **The audit log also records the admin writes that exist today**: seasons, boards, baselines,
  runner keys and roles. `season_map_events` and `baseline_events` stay, since pairing reads them.
- **Thread state stays off `matches`.** A `threads` row per host holds the lock and the count, so
  a comment never updates the match row that claim, renew and finish update in a loop.

## Schema

All of it goes into the one rewrite of `0001_init.sql` and `0002_sessions.sql`. No existing column
changes meaning.

| Table or column | Holds | Notes |
|---|---|---|
| `threads` | `match_id` or `model_id` (CHECK exactly one), `locked_at`, `locked_by`, `comments` | made on the first comment or lock |
| `comments` | `id`, `thread_id`, `parent_id`, `root_id`, `author_id`, `body` up to 500, `state` (live, held, removed, deleted), `hold_tag`, `created_at`, `decided_at`, `decided_by` | `root_id` makes "twenty threads with their replies" one indexed read |
| `comment_reports` | `comment_id`, `reporter_id`, `reason` from a fixed list, `words` up to 200, `created_at` | unique per reporter and comment |
| `comment_words` | `word`, `added_by`, `added_at`, `removed_at`, `removed_by` | the check reads rows with `removed_at IS NULL` |
| `users.bio` | up to 160 characters | refused on a listed word; a URL stays plain text |
| `users.comments_off_until`, `.comments_off_reason` | an end time, `infinity` for good | history in `audit_log` |
| `model_versions.note` | up to 120 characters | refused on a listed word |
| `model_stories` | `model_id` PK, `title`, `pending_title`, `body`, `pending_body`, `hold_tag`, `featured_at`, `updated_at`, `approved_at`, `removed_at` | the public reads `body`; the owner also reads `pending_body` |
| `posts` | `id`, `slug` unique and editable, `title`, `author_id`, `body`, `published_at` (null for a draft), `updated_at` | unpublish clears `published_at` |
| `announcements` | `kind` (notice, season, maintenance, incident), `body` up to 200, `link` (a site path or `https://`), `dismissable`, `ends_at`, `published_by`, `published_at`, `disabled_at`, `disabled_by` | live: not disabled, not past `ends_at` |
| `notify_sends` | `id`, `subject`, `link`, `audience` jsonb, `sent_by`, `sent_at`, `recipients` | each recipient gets a `notifications` row keyed `notify:<id>` |
| `picks` | `match_id`, `position`, `pinned_by`, `pinned_at`, `unpinned_at`, `unpinned_by` | partial unique index on live picks |
| `audit_log` | `id`, `admin_id`, `action`, `target_kind`, `target_id`, `reason`, `detail` jsonb, `at` | written inside the admin write's statement |
| `watch_events` | `match_id` (null for `visit`), `day`, `event` (visit, opened, finished), `via`, `n` | key on the first four, `NULLS NOT DISTINCT`, upserted `n = n + 1`; no user, no address |
| `season_podium` | `season_id`, `ladder`, `place` 1 to 3, `version_id`, `owner_id`, `rating` | written by the close, baselines skipped; unique on `(season_id, ladder, owner_id)` |
| `match_frames` | `match_id` PK, `turn`, `frame` jsonb | the runner's last frame, opaque, written by `finish`; a size CHECK; its own table so the match row stays small |
| `matches.margin` | first's score minus second's; null for a shared first place | set by count's fold |
| `matches.upset` | the best conservative rating before the match among beaten seats, disqualified ones left out, minus the winner's, Open ladder | set by count's fold; positive is an upset |
| `season_maps.size`, `.terrain`, `.hills` | from the name, and the file's `hills` count | CHECK on the name pattern |

**Functions**, each shared by several statements:

- `text_hold_tag(body)`: the listed word, or `link`, that holds or refuses a text, else null.
  Comments, stories, bios and notes call it, so every route refuses a text for the same reason.
  Postgres has the regex datalogic lacks.
- `match_summary_json(match)`: the card. The list, related, picks and channel routes return one
  shape, with `margin`, `upset`, `comments` and `frame` (whether a last frame exists) added.
- `comment_json(comment)`: the public row, with `deleted` rows kept as placeholders while they
  have replies.
- `rating_series(season, ladder, since, points)`: the bucketed series.
- `season_map_header()` gains `hills`; `season_map_name(id)` splits the name into size, terrain,
  players and hills, or answers null.

**The board name pattern** is `^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$`, with the size and terrain words
stored as given. Soma keeps no list of sizes or terrains: web's chips list the words the season's
boards carry, sizes ordered by their boards' median area. A second game with other words needs no
schema change.

**Indexes.** `matches (season_id, margin, id)`, `(season_id, upset DESC, id)` and
`(season_id, turns DESC, id)`, each partial on public finished rows. `comments (thread_id, root_id,
created_at)`, `comments (author_id, created_at DESC)` and `comments (created_at) WHERE state =
'held'`.

## Connectors

None new. No media bucket, no new deployment setting.

## Public routes

Each of these is caller-invariant and cached.

| Route | Returns | Serves |
|---|---|---|
| `GET /v1/matches` + `sort=newest\|closest\|upset\|longest\|discussed`, `since=`, `top=` | cards with `margin`, `upset`, `comments`, `frame`; a cursor per sort | home channels and shelves, `/matches` |
| `GET /v1/matches/{id}/frame` | `{id, map, turn, seats, frame}`: the last frame and each seat's score and rank; `frame` null before the match finishes or when the runner sent none, and the browser draws turn zero from the board. `Cache-Control: public, max-age=31536000, immutable` once finished | every card, Tile and Thumb |
| `GET /v1/matches/{id}/related` | twelve cards: six of these models with the winner's first, three on the board, then the latest | watch rail |
| `GET /v1/games/{game}/picks` | pinned cards in order | Staff picks channel |
| `season_json()` + `playing` | claimed and running matches of the season, trials excluded | season strip, `/matches` header |
| `GET /v1/games/{game}/leaderboard/series?ladder=&since=&points=` | per version, the rating at each bucket edge | sparkline, Trend, Rank race, Movers, model banner |
| `GET /v1/games/{game}/seasons/{slug}/podium` | the frozen podium, each place with its owner's latest match | closed leaderboard |
| `GET /v1/models/{id}/season` | record, last five, best win, worst loss, rank now and a week ago | model's This season |
| `GET /v1/models/{id}/rivals` | per opponent model: played, won, lost | home's Your season |
| `GET /v1/models/{id}/story` | the approved title and story, featured, updated | model page |
| `GET /v1/threads?match=\|model=` | twenty top-level comments with their replies, the count, the lock, a cursor | watch, model |
| `GET /v1/profiles/{handle}/comments` | the author's live comments with host and link | profile |
| `GET /v1/profiles/{handle}` + `bio`, `medals` | medals from `season_podium` | profile |
| `GET /v1/stories?kind=all\|team\|model` | posts and featured stories, newest first | home shelf, `/blog` |
| `GET /v1/posts/{slug}` | one published post | `/blog/:slug` |
| `GET /v1/announcements` | live announcements: id, kind, body, link, dismissable | every page |
| `GET .../seasons/{slug}/maps` + `size`, `terrain`, `hills`, `latest_match` | stored fields | `/maps`, the Board chip |
| `POST /v1/events` | 204; body `{event, match, via}`; address rate limit; no cookie; not cached | measuring |

`GET /v1/matches/{id}` and the public listing also hide trials in progress (finding 1).

## Signed-in routes

| Route | Does |
|---|---|
| `POST /v1/threads/comments` | posts a comment or reply; holds on `text_hold_tag`; refuses a locked thread, a switched-off author, a second comment inside 15 s or a 101st in a day, with `retry_after` |
| `DELETE /v1/comments/{id}` | sets `deleted`: a DELETE route whose statement is an UPDATE |
| `POST /v1/comments/{id}/reports` | files a report |
| `GET /v1/me/comments?host=` | the caller's held comments on that host |
| `PUT /v1/models/{id}/story`, `GET /v1/me/models/{id}/story` | writes the story, held on a listed word; reads the waiting text |
| `PATCH /v1/versions/{id}` | sets the note |
| `PATCH /v1/me` + `bio` | sets the bio |

Stories and posts are text: headings, links and lists. A post can name a match, which web draws
with the viewer. Neither carries a picture.

## Admin routes

Every write inserts its `audit_log` row in the same statement, as a data-modifying CTE, with the
reason where the page asks for one.

- **Comments**: held oldest first, reported most first, all with search; approve, remove and
  restore, one or a selection; lock and unlock a thread; the word list, add and remove.
- **Users**: held, reported and removed counts per row; commenting off for a day, a week, a month
  or for good; on again; the user's desk, joining their models, comments, reports and audit lines.
- **Announcements**: live and past; publish; disable.
- **Notify**: count an audience as its chips change; send as one `INSERT ... SELECT`; the log with
  recipients and how many read it.
- **Posts**: drafts and published; write, publish, unpublish.
- **Stories**: every story with its state; feature, unfeature; approve and remove a held edit.
- **Picks**: pin by match id, reorder, unpin.
- **Audit**: newest first, searchable by admin and by action.
- **Seasons**: the board upload refuses a name off the pattern, or whose `Np` or `Hh` disagrees
  with the file, and stores size, terrain and hills.

## Clocks

No new clock.

- **count**: the fold also writes `matches.margin` and `matches.upset`, inside the fenced
  statement, so a halted run writes neither. The trial verdicts, `pass` and `reject`, write
  `margin`.
- **withdraw**: the close also inserts `season_podium`, then a `medal` notification per placed
  owner as its own keyed statement.
- **pair, admit, reap**: unchanged.

## Runner gate

- `soma-gate-replay-url` is unchanged.
- `soma-gate-finish` binds `data.req.frame`, optional, and inserts it into `match_frames` in the
  same statement as the result, under the same claim. `runner_gate` gains `INSERT ON
  match_frames`, argued on the grant block. The CHECK on the frame's size refuses an oversized
  one, so the runner sends the frame only when it fits, and a match never fails for want of one.
- Kalam's side is `kalam/proposal/`. A runner that sends no frame leaves the card on turn zero.

## Notifications

`notifications_kind_known` gains `comment`, `reply`, `broadcast` and `medal`, and
`notification_category_spec()` gains `community`: app only, levels `all`, `replies` and `off`,
default `replies`. A broadcast sits in `season`, which you can switch off.

| Kind | To | Dedupe key |
|---|---|---|
| `reply` | the parent's author | `reply:<comment>` |
| `comment` | the model's owner, or each owner seated in the match | `comment:<thread>:<hour>`, one per thread per hour |
| `broadcast` | the audience | `notify:<send>` |
| `medal` | each placed owner | `medal:<season>:<ladder>` |

Each is a separate `continue_on_error` write after the decision. The bell draws new chips from new
`data` keys, and web's `Notifications.tsx` learns them in the same change.

## Order of work

1. **Schema.** Every table, column, function, index, grant and category above, in one rewrite, with
   `check-sql.sh` and `verify/run.sh` passing. New fixtures: the public listing hiding a trial in
   progress and showing a promoted one; a comment held for a URL; the rate limit; a locked thread;
   an admin write and its audit row; a close that writes a podium without its baseline.
2. **Catalogue**, which the shell, home, watch, matches, leaderboard and maps need: sorts, related,
   picks read, `playing`, series, podium, model season, rivals, map fields, events, announcements
   read, the frame in the gate and its route.
3. **Community**: threads, comments, reports, words, commenting off, the comments and users
   desks, audit.
4. **Editorial**: stories, posts, the announcement and pick writes, Notify.

Steps 2 to 4 can each ship as a Soma release of its own without touching the schema. Web ships once
all four are in. A card shows a last frame only once kalam sends one, and the schema must land
before a runner sends `frame`.

## Production cutover

Production holds a ladder, and `bootstrap` refuses a database built from other bytes. Every change
above adds a table, a nullable column, a function or an index, so the bump restores cleanly:

1. Close the season, or stop the runners and the clocks.
2. `pg_dump --data-only` every existing table.
3. Rebuild from the new migrations and restore. The new tables start empty.
4. Run a one-off statement from `scripts/` that fills `margin` and `upset` for past matches,
   `size`, `terrain` and `hills` for past boards, and `season_podium` for every closed season.
   Past matches have no last frame, so their cards rest on turn zero.
5. Check the rating chain (`rating_events` against `ratings.matches_played`) and the row counts
   before the runners come back.

If a change turns out not to be additive, the restore takes a transform step between 2 and 3 in
the same script. A season boundary is the cheapest moment: nothing is in flight, and the next
season's boards upload under the name rule. That same boundary is when ants' new engine lands
(`ants/proposal/`).

## Open questions

None. `PLAN.md` records the answers (§3).
