# Soma: implementation plan for the web redesign

This plan turns `proposal/README.md` into work. I checked the proposal against its consumer, every
page file in `web/proposal/`, and against the package at `b6f3b7a`. Sections 1 and 2 say what held
and what did not, section 3 records the decisions, and the rest is the order to build it in.

## 1. The proposal's findings, checked

All twelve findings hold. Four needed a correction or a wider fix, and the README now carries each.

| # | Verdict | Evidence, and the correction |
|---|---|---|
| 1 | Holds, and goes wider | `soma-pub-matches-list-query.sql` returns trials when `?model=` or `?version=` is set, and `GET /v1/matches/{id}` serves any row by id. Wider: `soma-pub-models-get` lists every version publicly, rejected and in-flight included, with `reject_reason`, and `soma-pub-versions-get` answers any version by id with its trial. See G1. |
| 2 | Holds | CLAUDE.md, *Only a caller-invariant route may declare `cache`*. |
| 3 | Replaced | The poster file and its presigned PUT are gone with the image storage. `ants/engine/src/replay.rs` stores actions only, so a last frame exists only where the final state does: on the runner, at `finish`. The runner sends it in the `finish` body and Soma keeps it in `match_frames`. |
| 4 | Holds | `soma-pub-matches-get` presigns for 1 h inside `hot_cache`. Cards fetch `GET /v1/matches/{id}/frame` instead, which needs no signing and tells the browser to keep it. |
| 5 | Holds | `backup/maps/large-cave-4p-3h.json` carries 12 `hills` (4 × 3); the five basic boards carry `players × H` too. |
| 6 | Holds, one gap | Count's `fold` reads `ratings` in the same snapshot, so `mark` can compute `upset` from pre-fold ratings in one statement. The trial verdicts (`pass`, `reject`) also mark a match `rated`, and finding 1 makes a promoted candidate's trial public, so those two write `margin` as well. |
| 7 | Holds | The leaderboard workflow's description says the chain "is not a public route". |
| 8 | Holds | Both routes default `limit` in a map task and never clamp it. |
| 9 | Holds | README, *Known gaps*: push is stored and not delivered. |
| 10 | Holds | `notifications.read_at` is the only read state. |
| 11 | Holds | |
| 12 | Holds | `scripts/check-names.sh` freezes 13 domains; kalam's list and web's `configs.sh` comparison change in the same step. |

The *What exists already* table holds row by row: `players_min`/`players_max`, `?owner=` without
trials, `?class=`, `?version=&limit=3`, `season_json()`'s counts, `season_map_json()`'s `matches`,
`seats.mine` on `/v1/me/matches`, and baseline profiles by `baseline.<slug>`.

Orion 1.9.1 lets a shaped response set headers (`_orion.response.headers`, allowed per channel by
`response.allowed_headers`), so the frame route can send `Cache-Control` itself.

## 2. Gaps: what the pages need that the proposal missed

Each gap names the page that needs it and the change. G10 is withdrawn; the numbers stay so
earlier references still point at the right item.

- **G1. Private versions leak.** `models-get` and `versions-get` return rejected and in-flight
  versions to anyone; model.md relies on "the owner's alone, as today", and only web enforces it.
  Move the version shape into one function, `version_json(v)`. The public routes return `active`,
  `disabled` and `superseded`; a new `GET /v1/me/versions/{id}` returns the rest to the owner, and
  `GET /v1/models` already lists them. A private version's permalink answers 404 publicly.
- **G2. A latest match per card.** Profile model cards draw the latest match and when it last
  played; the podium draws the champion's last match with Watch; maps' Watch opens a board's latest
  match. One function, `match_ref_json(match_id)` returning `{id, played_at, frame}` (`frame`
  says whether a last frame exists), feeds `latest_match` on each profile model, podium place and
  season map.
- **G3. Head to head.** Home's "the neighbour you lose to most" links to that model's matches
  against yours. Add `?vs=<model id>` to `GET /v1/matches`, valid only beside `?model=`.
- **G4. The Owner tag.** model.md tags the owner's comments. `comment_json()` returns `owner`: on a
  model thread the author owns the model, on a match thread the author owns a seated version.
- **G5. The composer's state and the bio.** comments.md shows a switched-off author the reason and
  the end time in the composer's place, and the account page edits the bio. `GET /v1/me` returns
  `bio`, `comments_off_until` and `comments_off_reason`.
- **G6. Stories have titles.** The Stories grid and the model page show a story's title.
  `model_stories` gains `title` and `pending_title`.
- **G7. A link holds a comment and not a story.** admin.md: "Links are a story's normal content".
  `text_hold_tag(body, p_links boolean)` takes the host's rule.
- **G8. The note at submit.** model.md writes the version note "at submit time and editable on the
  row". The submission create takes `note`, beside `PATCH /v1/versions/{id}`.
- **G9. Posts need an id.** admin.md edits the slug on the Write page. Key `posts` by a uuid `id`
  and keep the slug unique and editable.
- **G10. Withdrawn.** It covered picture uploads and the media proxy, which are out.
- **G11. The series must hold the field at the time.** Rank race ranks "among every version on the
  ladder" at each reading, and a model's banner line spans its versions. The series returns every
  version that stood on the ladder at any edge in the window, `null` where it did not, with its
  `model_id` so web can join a model's versions into one line. No column records promotion or
  supersession; `rating_events` seq 0 gives both (a version's own, and its successor's). One
  function, `ladder_at(season, ladder, t)`, answers the field and each version's conservative
  rating at `t`; the series and the model's "rank a week ago" both call it. It needs an index the
  proposal lacks: `rating_events (version_id, ladder, created_at)`.
- **G12. Most discussed.** `threads.comments` moves with every comment, so a keyset cursor on it
  drifts. Rank it over a `since` window with an OFFSET cursor, the way the leaderboard ranks a live
  number.
- **G13. Upset and margin, defined.** `upset` is the best conservative rating before the match
  among beaten seats, disqualified seats left out, minus the winner's, on Open. `margin` is the
  rank-1 score minus the rank-2 score, `null` for a shared first place. matches.md calls the upset
  "the largest rating swing"; web's copy should take this definition.
- **G14. The close's rank and the podium disagree.** `notify_closed` ranks the Open field with
  baselines in it. Rank it the podium's way: no baselines, one place per owner.
- **G15. A medal's category** is `season`.
- **G16. Measuring.** A `visit` event gives "matches opened per visit", and
  `GET /v1/admin/events?since=` reads the three numbers per day.
- **G17. Announcement links** take a site path or an `https://` URL. Notify stays site paths only.
- **G18. The user's desk shows sign-ins.** The desk route reads `sessions` (issued, last seen, user
  agent) for that user; an admin route may, a clock may not.
- **G19. Pagination.** `/v1/stories` loads twenty with Load more, so it takes a cursor. An admin
  previews a draft through `GET /v1/admin/posts/{id}`.
- **G20. What a pick may name.** A public match only: finished or rated, and no trial in progress.
- **G21. Board names in production.** A CHECK on `season_maps.map_id` would refuse the restore if
  any stored board breaks the pattern. Keep `size`, `terrain` and `hills` nullable, refuse
  off-pattern names at upload, and run the check query in *Cutover* first.
- **G22. Closed seasons need their podium.** The cutover's backfill writes `season_podium` for
  every season already closed.
- **G23. The event route and missing matches.** `watch_events.match_id` is a foreign key, so a POST
  naming a random id would be a 500. The insert selects from `matches` and writes nothing for a
  match that is not public; the route answers 204 either way.
- **G24. Frames cost database space.** About 55 matches an hour at a few KB each is roughly 4 MB a
  day on Postgres. `match_frames` gets a size CHECK (64 KB of text), and its retention joins the
  README's *Known gaps*.

## 3. Decisions

| # | Question | Answer |
|---|---|---|
| D1 | The new tag domain | `community`, for comments, words, stories, posts and picks |
| D2 | Top of the ladder | Two or more seats in today's Open top ten |
| D3 | The bio | Refused on a listed word; a URL is allowed and drawn as plain text |
| D4 | Visits | A `visit` event, one per page load, no match, no user |
| D5 | Announcement links | A site path or `https://`; Notify stays site paths |
| D6 | Branches | All redesign work stays on `tinybrainsv2` until it is stable for release. `main` stays clean for production fixes |
| D7 | Images | No image storage anywhere. The browser draws boards and frames with the viewer and keeps them in its cache. Soma serves the last frame as JSON. Stories and posts are text |
| D8 | The podium | One place per owner: each owner's best version stands for them, then the top three owners. Baselines skipped |
| D9 | Upset, margin | As G13 |
| D10 | Medals | Category `season` |
| D11 | Most discussed | Over a `since` window, OFFSET cursor |
| D12 | Podium card | Each place carries its owner's latest match |

**Working on the branch (D6).** `tinybrainsv2` in each repository the redesign touches. Two things
keep it honest:

- A production fix lands on `main` first and is merged into `tinybrainsv2` straight after, so the
  branch never loses a fix and the final merge back is a fast-forward.
- Ants' CI builds the CLI from cli's `main`, so cli's redesign changes reach cli's `main` before any
  ants change that needs them, or ants' CI points at cli's branch while both are in flight.

## 4. The work

Four steps. Step 1 is the only schema change and the only production rebuild; steps 2 to 4 are
package applies. Each step ends with `check-defs.sh`, `check-sql.sh` and `verify/run.sh` passing,
the verify output diffed against a `git archive` copy of the step before.

### Step 1: schema, and the fixes that need no new route

**`0001_init.sql`**

- `season_maps`: `size text`, `terrain text`, `hills smallint`, all nullable;
  `season_map_name(map_id)` (the pattern `^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$` split into size,
  terrain, players, hills, else null), and `season_map_header()` gaining `hills` (the length of
  the file's `hills` array, which must be a multiple of `players`).
- `matches`: `margin int`, `upset float8`; three partial indexes on public finished rows,
  `(season_id, margin, id)`, `(season_id, upset DESC, id)`, `(season_id, turns DESC, id)`.
- `match_frames`: `match_id` PK references `matches`, `turn int`, `frame jsonb`, a CHECK that the
  frame is an object of at most 64 KB as text.
- `model_versions.note` (up to 120). `users.bio` (up to 160), `users.comments_off_until`,
  `users.comments_off_reason`.
- New tables from the README's schema table: `threads`, `comments`, `comment_reports`,
  `comment_words`, `model_stories` (with `title`, `pending_title`), `posts` (uuid `id`, unique
  `slug`), `announcements`, `notify_sends`, `picks`, `audit_log`, `watch_events` (`match_id`
  nullable for `visit`, unique `NULLS NOT DISTINCT`), `season_podium` (with `owner_id`, unique on
  `(season_id, ladder, owner_id)` and on `(season_id, ladder, place)`).
- Indexes: the README's comment indexes, `rating_events (version_id, ladder, created_at)`, the
  partial unique index on live picks, `audit_log (at DESC)`, `audit_log (admin_id, at DESC)`.
- Functions: `text_hold_tag(body, p_links)`, `version_json(v)`, `match_ref_json(id)`,
  `match_summary_json(id)` (today's list row plus `margin`, `upset`, `comments` and `frame`),
  `comment_json(c)` (with `owner`), `ladder_at(season, ladder, t)`,
  `rating_series(season, ladder, since, points)`, `podium_of(season, ladder)` (the close and the
  backfill call the same one), `match_public(m)` (finished or rated, and either no trial or a trial
  whose candidate is `active` or `superseded`), and `season_json()` gaining `playing`.
- Grants: `runner_gate` gains `INSERT ON match_frames`, argued on the grant block.

**`0002_sessions.sql`**

- `notifications_kind_known` gains `comment`, `reply`, `broadcast`, `medal`.
- `notification_category_spec()` gains `community`: app only, levels `all`, `replies`, `off`,
  default `replies`.

**Routes that change in step 1**, since each is a statement edit and the schema already carries
what it needs:

- `soma-pub-matches-list`: `match_public()` replaces the trial clause; `limit` clamps at 60 in SQL;
  each row comes from `match_summary_json()`.
- `soma-pub-matches-get`: answers 404 for a trial in progress.
- `soma-pub-models-get`, `soma-pub-versions-get`: public statuses only (G1), and the note.
- `soma-pub-leaderboard`: `limit` clamps at 200.
- `soma-gate-finish`: binds `data.req.frame`, optional, and inserts it into `match_frames` inside
  the same statement as the result, under the same claim. A missing frame writes no row.
- Count's `fold`, `pass` and `reject`: write `margin`; `fold` writes `upset`.
- Withdraw's `close`: inserts `season_podium` from `podium_of()` in the same statement; a new
  `notify_medal` task after it, `continue_on_error`, keyed `medal:<season>:<ladder>`.
  `notify_closed` ranks the podium's way (G14).
- `soma-admin-maps-add`: refuses a name off the pattern, or whose `Np` or `Hh` disagrees with the
  file, with a 422 naming which; stores the three fields.
- Every existing admin write inserts its `audit_log` row as a data-modifying CTE: seasons create,
  update and close; maps add and update; baselines add and update; runner keys create and revoke;
  runners revoke; users update.
- `soma-user-me`: returns `bio`, `comments_off_until`, `comments_off_reason`.
  `soma-user-me-update`: sets `bio` under D3.
- `soma-user-submissions-create`: takes `note`.

**No connector, bucket or deployment setting changes.**

**Across repositories, in this step**: `community` in kalam's `check-names.sh`, read by web's
`configs.sh`; web's `Notifications.tsx` learns the four kinds and their `data` keys in the change
that first writes them.

**New fixtures in `verify/scenario.sql`**: the public list hiding a trial in progress and showing a
promoted one; a private version 404ing publicly; `finish` with a frame writing `match_frames`,
without one writing none, and with an oversized one refused; a fold writing `margin` and `upset`,
with a DQ seat left out; a trial pass writing `margin`; a close writing a podium that skips the
baseline and gives one owner one place, and a medal row per placed owner; an admin write and its
audit row; a board upload refused for `Hh`; a comment held for a URL; the 15 s and 100-a-day
refusals; a locked thread refusing a comment.

### Step 2: catalogue

Public, cached, one release. Domains in brackets.

- `GET /v1/matches/{id}/frame`: `{id, map, turn, seats, frame}`, public matches only.
  `Cache-Control: public, max-age=31536000, immutable` once a frame exists, a short max-age while
  `frame` is null. The browser draws the board, which it has from the maps route's
  `?boards=true`, and the frame over it. [matches]
- `GET /v1/matches` gains `sort=newest|closest|upset|longest|discussed`, `since=`, `top=`, `vs=`,
  with a cursor per sort. [matches]
- `GET /v1/matches/{id}/related`: twelve cards, six of these models with the winner's first, three
  on the board, then the latest, deduplicated, the match itself excluded. [matches]
- `GET /v1/games/{game}/picks`: pinned cards in order. [matches]
- `GET /v1/games/{game}/leaderboard/series?ladder=&since=&points=`. [ladder]
- `GET /v1/games/{game}/seasons/{slug}/podium`, with `latest_match` per place. [ladder]
- `GET /v1/models/{id}/season`: record, last five, best win and worst loss by rating change, rank
  now and a week ago through `ladder_at()`. [models]
- `GET /v1/models/{id}/rivals`: per opposing model this season, played, won and lost, where a win
  is a better rank in a rated, non-trial match both sat in. [models]
- `GET /v1/profiles/{handle}` gains `bio`, `medals` and, per model, `latest_match`. [profile]
- `season_map_json()` gains `size`, `terrain`, `hills`, `latest_match`. [maps]
- `GET /v1/announcements`: live ones, newest first. [platform]
- `POST /v1/events`: `{event, match, via}`, 204, address rate limit, no auth, not cached. [matches]
- `GET /v1/admin/events?since=`: visits, opened by `via`, finished, per day. [matches]

### Step 3: community

- Public: `GET /v1/threads?match=|model=` (twenty roots with replies, count, lock, cursor);
  `GET /v1/profiles/{handle}/comments`. [community]
- Signed in: `POST /v1/threads/comments`; `DELETE /v1/comments/{id}` (an UPDATE to `deleted`);
  `POST /v1/comments/{id}/reports`; `GET /v1/me/comments?host=`. Each comment write updates
  `threads.comments` in its own statement, and the `reply` and `comment` notifications follow as
  `continue_on_error` writes. [community]
- Admin: the comments desk (held, reported, all with search), approve, remove and restore over a
  selection, lock and unlock, the word list; the users list's counts; commenting off and on; the
  user's desk with sign-ins; the audit log with search. Each write carries its audit row.
  [community, users]

### Step 4: editorial

- Public: `GET /v1/models/{id}/story`, `GET /v1/stories?kind=&cursor=`, `GET /v1/posts/{slug}`.
  [community]
- Signed in: `PUT /v1/models/{id}/story`, `GET /v1/me/models/{id}/story`,
  `PATCH /v1/versions/{id}` for the note. [community, models]
- Admin: posts (list, read a draft, save, publish, unpublish), stories (list, feature, unfeature,
  approve and remove a held edit), announcements (list, publish, disable), Notify (count an
  audience, send as one `INSERT ... SELECT`, the log with recipients and reads), picks (pin under
  G20, reorder, unpin). [community, platform, notifications, matches]

## 5. Cutover

Production rebuilds once, when the step 1 image deploys. Before anything stops, run on production:

```sql
SELECT map_id FROM season_maps WHERE map_id !~ '^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$';
SELECT slug FROM seasons WHERE closed_at IS NOT NULL;
```

The first list keeps `null` board fields after the restore (G21); the second is what the podium
backfill covers (G22). Then follow the README's five steps. The one-off script in `scripts/` fills
`margin` and `upset` for past rated matches, the board fields, and `season_podium` for each closed
season through `podium_of()`, without medal notifications. Past matches have no frame, so their
cards rest on turn zero. The rating-chain check reads `ratings.matches_played` against
`max(rating_events.seq)`, which CLAUDE.md says a restore must keep.

## 6. Other repositories' proposals this changes

D7 removes the media bucket and the poster file, so these need rewriting in their own folders:

- **kalam**: no poster PUT and no second presign. After `results`, call the engine's frame function
  and send its answer as `frame` in the `finish` body, only when it fits the 64 KB limit.
- **ants**: the `poster` function answers the last frame's moving layer (ants, food, hills, scores)
  and not the board, which Soma already holds. It still moves the engine digest, so it still ships
  at a season boundary. `drawPoster` takes the board and the frame.
- **web**: the *Media proxy* section, the media bucket in both compose files, and picture uploads in
  model.md, blog.md and admin.md go. Cards fetch `/v1/matches/{id}/frame` and keep what they draw.

## 7. What stays out

No new clock. No push delivery. No `opened` state on a notification. No page per board. No editing
of comments. No stored image. Retention of `watch_events`, `audit_log` and `match_frames` joins the
README's *Known gaps* in step 1.
