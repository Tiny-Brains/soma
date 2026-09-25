# Soma: implementation plan for the web redesign

This plan turns `proposal/README.md` into work. I checked the proposal against its consumer, every
page file in `web/proposal/`, and against the package at `b6f3b7a`. The first two sections say what
held and what did not; the rest is the order to build it in. The work lands on the `tinybrainsv2`
branch. This file goes with the proposal folder when the redesign ships.

## 1. The proposal's findings, checked

All twelve findings hold. Four need a correction or a wider fix.

| # | Verdict | Evidence, and the correction |
|---|---|---|
| 1 | Holds, and goes wider | `soma-pub-matches-list-query.sql` returns trials when `?model=` or `?version=` is set, and `GET /v1/matches/{id}` serves any row by id. Wider: `soma-pub-models-get` lists every version publicly, rejected and in-flight included, with `reject_reason`, and `soma-pub-versions-get` answers any version by id with its trial. See gap G1. |
| 2 | Holds | CLAUDE.md, *Only a caller-invariant route may declare `cache`*. |
| 3 | Holds | The runner calls `/replay-url`, PUTs, then `finish`. `finish` takes `replay_key` from the runner's body (`data.req.replay_key`); the poster key should come from the claim instead, as the proposal says, which is stricter. It needs a `poster_prefix` var beside `replay_prefix`. |
| 4 | Holds | `soma-pub-matches-get` presigns for 1 h inside `hot_cache`. |
| 5 | Holds | `backup/maps/large-cave-4p-3h.json` carries 12 `hills` (4 × 3); the five basic boards carry `players × H` too. |
| 6 | Holds, one gap | Count's `fold` reads `ratings` in the same snapshot, so `mark` can compute `upset` from pre-fold ratings in the same statement. The trial verdicts (`pass`, `reject`) also mark a match `rated`, and finding 1 makes a promoted candidate's trial public, so those two statements must write `margin` as well. |
| 7 | Holds | The leaderboard workflow's description says the chain "is not a public route". |
| 8 | Holds | Both routes default `limit` in a map task and never clamp it. |
| 9 | Holds | README, *Known gaps*: push is stored and not delivered. |
| 10 | Holds | `notifications.read_at` is the only read state. |
| 11 | Holds | |
| 12 | Holds | `scripts/check-names.sh` freezes 13 domains; kalam's list and web's `configs.sh` comparison must change in the same step. |

The *What exists already* table holds row by row: `players_min`/`players_max`, `?owner=` without
trials, `?class=`, `?version=&limit=3`, `season_json()`'s counts, `season_map_json()`'s `matches`,
`seats.mine` on `/v1/me/matches`, and baseline profiles by `baseline.<slug>`.

Kalam's proposal agrees with the gate contract: `poster_url` beside `url` on `/replay-url`,
`poster: true|false` on `finish`, and `kalam-blobs-put` already sends `content-type:
application/json`, which matches the content type the poster presign signs.

## 2. Gaps: what the pages need that the proposal misses

Each gap names the page that needs it and the change I propose.

- **G1. Private versions leak.** `models-get` and `versions-get` return rejected and in-flight
  versions to anyone; model.md relies on "the owner's alone, as today", and web enforces that
  alone. Move each route's version shape into one function, `version_json(v)`. The public routes
  return `active`, `disabled` and `superseded` only; a new `GET /v1/me/versions/{id}` returns the
  rest to the owner, and `GET /v1/models` already lists them. A private version's permalink answers
  404 publicly.
- **G2. A latest match per card.** Profile model cards draw "the latest match as a Thumb" and when
  it last played; the leaderboard podium draws the champion's last match with Watch; maps' Watch
  opens a board's latest match. Add one function, `match_ref_json(match_id)` returning `{id,
  poster_url, played_at}`, and use it for `latest_match` on each profile model, each podium row and
  each season map.
- **G3. Head to head.** Home's "the neighbour you lose to most" links to that model's matches
  against yours. Add `?vs=<model id>` to `GET /v1/matches`, valid only beside `?model=`.
- **G4. The Owner tag.** model.md tags the owner's comments. `comment_json()` returns `owner`:
  on a model thread the author owns the model, on a match thread the author owns a seated version.
- **G5. The composer's state and the bio.** comments.md shows a switched-off author the reason and
  the end time in the composer's place, and the account page edits the bio. `GET /v1/me` returns
  `bio`, `comments_off_until` and `comments_off_reason`.
- **G6. Stories have titles.** The Stories grid and the model page show a story's title ("How Gaemi
  reads a board it cannot see"). `model_stories` gains `title` and `pending_title`.
- **G7. A link holds a comment and not a story.** admin.md: "Links are a story's normal content".
  `text_hold_tag(body, p_links boolean)` takes the host's rule. Bios conflict: profile.md holds a
  bio on a listed word and leaves a URL as text, and the proposal refuses both. Decision D3.
- **G8. The note at submit.** model.md writes the version note "at submit time and editable on the
  row". The submission create takes `note` as well as `PATCH /v1/versions/{id}`.
- **G9. Posts need an id.** admin.md edits the slug on the Write page, and `pictures.post_slug`
  would orphan every picture on a rename. Key `posts` by a uuid `id`; the slug stays unique and
  editable, and `pictures.post_id` points at the id.
- **G10. Pictures need a trigger and a gate.** The proposal HEADs a picture after upload and adds
  no clock, so nothing runs the HEAD. Orion's storage connector has `presign_get`, `presign_put`
  and `head` and nothing else (`connector/config.rs`), so Soma cannot delete an object. The media
  proxy would then serve a refused, removed or never-confirmed upload at `/media/<key>` for good.
  Two changes: `POST /v1/pictures/{id}/check`, which the browser calls after its PUT, HEADs the
  object and sets `ready` or `refused`; and `GET /v1/media-check?key=`, which answers 204 for a
  `ready` picture that nobody removed and 404 otherwise, for the proxy's `auth_request` (nginx) and
  `forward_auth` (Caddy), the pattern `/v1/admin-check` already uses. Posters skip the check: only
  the gate signs them.
- **G11. The series must hold the field at the time.** Rank race ranks "among every version on the
  ladder" at each reading, and a model's banner line spans its versions. The series returns every
  version that stood on the ladder at any edge in the window, `null` where it did not, with its
  `model_id` so web can join a model's versions into one line. Neither promotion nor supersession
  has a timestamp column; both come from `rating_events` seq 0 (promotion) and the successor's seq
  0 (supersession). One function, `ladder_at(season, ladder, t)`, answers the field and each
  version's conservative rating at `t`, and the series and the model's "rank a week ago" both call
  it. It needs an index the proposal lacks: `rating_events (version_id, ladder, created_at)`.
- **G12. Most discussed.** `threads.comments` moves with every comment, so a keyset cursor on it
  drifts, and the proposal lists no index. Rank it the way the leaderboard ranks a live number:
  an OFFSET cursor over a `since` window.
- **G13. Upset and margin, defined.** home.md measures an upset by the ratings the page prints,
  which are conservative. Store `upset` as the best conservative-before among beaten seats minus
  the winner's, on Open, with disqualified seats left out of "beaten": a forfeit is no upset.
  `margin` is the rank-1 score minus the rank-2 score, and `null` for a shared first place.
  matches.md calls the upset "the largest rating swing"; web's copy should take this definition.
- **G14. The close's rank and the podium disagree.** `notify_closed` ranks the Open field with
  baselines in it ("You finished 3rd"), and the podium skips baselines. Rank both without baselines.
- **G15. A medal's category.** The proposal names none. Put `medal` in `season`.
- **G16. Measuring.** The README tracks "matches opened per visit", and two events without a visit
  cannot give it. Nothing reads `watch_events` either. Decision D4, and an admin read route.
- **G17. Announcement links.** Notify's link lands in `notifications`, whose CHECK takes a site
  path only. An announcement may want Discord. Decision D5.
- **G18. The user's desk shows sign-ins.** admin.md lists them. The desk route reads `sessions`
  (issued, last seen, user agent) for that user; an admin route may, a clock may not.
- **G19. Pagination the proposal leaves out.** `/v1/stories` loads twenty with Load more, so it
  takes a cursor. An admin previews a draft, so `GET /v1/admin/posts/{id}` reads one unpublished.
- **G20. What a pick may name.** A pin takes a public match only: finished or rated, and not a
  trial in progress.
- **G21. Board names in production.** A CHECK on `season_maps.map_id` refuses the restore if any
  stored board breaks the pattern (a `basic-*` board uploaded into a season would). Keep `size`,
  `terrain` and `hills` nullable, refuse off-pattern names at upload, and run the check query in
  *Cutover* on production before the rebuild.
- **G22. Closed seasons need their podium.** The cutover's backfill fills `margin`, `upset` and the
  board fields, and must also write `season_podium` for every season already closed.
- **G23. The event route and missing matches.** `watch_events.match_id` is a foreign key, so a POST
  naming a random id is a 500. The insert selects from `matches` and writes nothing for a match
  that is not public; the route answers 204 either way.

## 3. Decisions before the schema

The schema is written once, so these six need an answer before step 1.

- **D1. The domain word.** `community`, as proposed. Recommended.
- **D2. Top of the ladder.** Two or more seats in today's Open top ten. Recommended. `top=` ranks
  the ladder as it stands now, not when the match was played.
- **D3. The bio rule.** The proposal refuses a bio with a listed word or a URL; profile.md holds it
  on a word and allows a URL as text. Recommended: refuse on a listed word, allow a URL as plain
  text, and update profile.md. A held bio would need a pending column and a desk tab for 160
  characters.
- **D4. Visits.** Either add a `visit` event (`match_id` null, keyed with `NULLS NOT DISTINCT`) that
  the shell posts once per page load, or drop "per visit" from web's README and track matches
  opened per day. Recommended: `visit`.
- **D5. Announcement links.** A site path or an `https://` URL. Notify stays path-only.
  Recommended.
- **D6. Where the plan's commits go.** Everything below lands on `tinybrainsv2`. When it merges,
  `main` fast-forwards and the branch goes, as CLAUDE.md's policy asks.

## 4. The work

Four steps, as the proposal orders them. Step 1 is the only schema change and the only production
rebuild; steps 2 to 4 are package applies. Each step ends with `check-defs.sh`, `check-sql.sh` and
`verify/run.sh` passing, the verify output diffed against a `git archive` copy of the step before.

### Step 1: schema, and the fixes that need no new route

**`0001_init.sql`**

- `season_maps`: `size text`, `terrain text`, `hills smallint`, all nullable; functions
  `season_map_name(map_id)` (the pattern `^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$` split into size,
  terrain, players, hills, else null) and `season_map_header()` gaining `hills` (the length of the
  file's `hills` array, checked as a multiple of `players`).
- `matches`: `poster_key text`, `margin int`, `upset float8`; three partial indexes on public
  finished rows, `(season_id, margin, id)`, `(season_id, upset DESC, id)`, `(season_id, turns
  DESC, id)`.
- `model_versions.note` (up to 120). `users.bio` (up to 160), `users.comments_off_until`,
  `users.comments_off_reason`.
- New tables, as the proposal's schema table lists them, with G6 and G9 applied: `threads`,
  `comments`, `comment_reports`, `comment_words`, `model_stories` (+ `title`, `pending_title`),
  `posts` (uuid `id`, unique `slug`), `pictures` (`post_id`), `announcements`, `notify_sends`,
  `picks`, `audit_log`, `watch_events`, `season_podium`. `watch_events.match_id` nullable if D4
  takes `visit`.
- Indexes: the comment indexes the proposal lists, `rating_events (version_id, ladder,
  created_at)` (G11), `picks` partial unique on live picks, `audit_log (at DESC)`, `audit_log
  (admin_id, at DESC)`, `pictures (story_model_id)`, `pictures (post_id)`.
- Functions: `text_hold_tag(body, p_links)`, `version_json(v)` (G1), `match_ref_json(id)` (G2),
  `match_summary_json(id)` (the card: today's list row plus `poster_url`, `margin`, `upset`,
  `comments`), `comment_json(c)` (with `owner`, G4), `ladder_at(season, ladder, t)` and
  `rating_series(season, ladder, since, points)` (G11), `match_public(m)` (finished or rated, and
  either no trial or a trial whose candidate is `active` or `superseded`), and `season_json()`
  gaining `playing`. `media_url(key)` builds `/media/<key>` in one place.
- Grants: `runner_gate` gains `UPDATE (poster_key) ON matches`, argued on the grant block beside
  `replay_key`.

**`0002_sessions.sql`**

- `notifications_kind_known` gains `comment`, `reply`, `broadcast`, `medal`.
- `notification_category_spec()` gains `community`: app only, levels `all`, `replies`, `off`,
  default `replies`.

**Routes that change in step 1**, since each is a statement edit and the schema already carries
what it needs:

- `soma-pub-matches-list`: `match_public()` replaces the trial clause (finding 1); `limit` clamps
  at 60 in SQL (finding 8); each row gains `poster_url`, `margin`, `upset` and `comments` through
  `match_summary_json()`.
- `soma-pub-matches-get`: answers 404 for a trial in progress; adds `poster_url`.
- `soma-pub-models-get`, `soma-pub-versions-get`: public statuses only (G1), and the note.
- `soma-pub-leaderboard`: `limit` clamps at 200.
- `soma-gate-replay-url`: signs `posters/<match>/<claim_token>.json` through the new
  `soma-media-gate` and returns `poster_url`. `soma-gate-finish`: binds `data.req.poster` and sets
  `poster_key` from the claim when it is `true`.
- Count's `fold`, `pass` and `reject`: write `margin`; `fold` writes `upset` (finding 6, G13).
- Withdraw's `close`: inserts `season_podium` in the same statement; a new `notify_medal` task after
  it, `continue_on_error`, keyed `medal:<season>:<ladder>`. `notify_closed` ranks without baselines
  (G14).
- `soma-admin-maps-add`: refuses a name off the pattern, or whose `Np` or `Hh` disagrees with the
  file, with a 422 naming which; stores the three fields.
- Every existing admin write inserts its `audit_log` row as a data-modifying CTE: seasons create,
  update and close; maps add and update; baselines add and update; runner keys create and revoke;
  runners revoke; users update.
- `soma-user-me`: returns `bio`, `comments_off_until`, `comments_off_reason` (G5).
  `soma-user-me-update`: sets `bio` under D3's rule.
- `soma-user-submissions-create`: takes `note` (G8).

**Connectors and configuration**: `soma-media` (`presign_put`, `head`) and `soma-media-gate`
(`presign_put`, signed for `RUNNER_BLOB_ENDPOINT`), both on `MEDIA_BUCKET`; `MEDIA_BUCKET` and
`poster_prefix` in `soma.toml.tmpl`, and the variable in web's two compose files.

**Across repositories, in this step**: `community` added to kalam's `check-names.sh` and read by
web's `configs.sh`; web's `Notifications.tsx` learns the four kinds and their `data` keys in the
change that first writes them.

**New fixtures in `verify/scenario.sql`**: the public list hiding a trial in progress and showing a
promoted one; a private version 404ing publicly; `finish` with `poster: true` setting `poster_key`
and with the field absent leaving it null; a fold writing `margin` and `upset`, with a DQ seat left
out; a trial pass writing `margin`; a close writing the podium without its baseline and a medal row
per placed owner; an admin write and its audit row; a board upload refused for `Hh`; a comment
held for a URL; the 15 s and 100-a-day refusals; a locked thread refusing a comment.

### Step 2: catalogue

Public, cached, one release. Domains in brackets.

- `GET /v1/matches` gains `sort=newest|closest|upset|longest|discussed`, `since=`, `top=`, `vs=`,
  with a cursor per sort (G3, G12). [matches]
- `GET /v1/matches/{id}/related`: twelve cards, six of these models with the winner's first, three
  on the board, then the latest, deduplicated, the match itself excluded. [matches]
- `GET /v1/games/{game}/picks`: pinned cards in order. [matches]
- `GET /v1/games/{game}/leaderboard/series?ladder=&since=&points=` (G11). [ladder]
- `GET /v1/games/{game}/seasons/{slug}/podium`, with `latest_match` per row (G2). [ladder]
- `GET /v1/models/{id}/season`: record, last five, best win and worst loss by rating change, rank
  now and a week ago through `ladder_at()`. [models]
- `GET /v1/models/{id}/rivals`: per opposing model this season, played, won and lost, where a win
  is a better rank in a rated, non-trial match both sat in. [models]
- `GET /v1/profiles/{handle}` gains `bio`, `medals` and, per model, `latest_match` (G2). [profile]
- `season_map_json()` gains `size`, `terrain`, `hills`, `latest_match`. [maps]
- `GET /v1/announcements`: live ones, newest first. [platform]
- `POST /v1/events`: 204, address rate limit, no auth, not cached (G23, D4). [matches]
- `GET /v1/admin/events?since=`: the three numbers, per day (G16). [matches]

### Step 3: community

- Public: `GET /v1/threads?match=|model=` (twenty roots with replies, count, lock, cursor);
  `GET /v1/profiles/{handle}/comments`. [community]
- Signed in: `POST /v1/threads/comments`; `DELETE /v1/comments/{id}` (an UPDATE to `deleted`);
  `POST /v1/comments/{id}/reports`; `GET /v1/me/comments?host=`. Each comment write updates
  `threads.comments` in its own statement, and the `reply` and `comment` notifications follow as
  `continue_on_error` writes. [community]
- Admin: the comments desk (held, reported, all with search), approve, remove and restore over a
  selection, lock and unlock, the word list; the users list's counts; commenting off and on; the
  user's desk with sign-ins (G18); the audit log with search. Each write carries its audit row.
  [community, users]

### Step 4: editorial

- Public: `GET /v1/models/{id}/story`, `GET /v1/stories?kind=&cursor=` (G19),
  `GET /v1/posts/{slug}`, `GET /v1/media-check?key=` (G10). [community]
- Signed in: `PUT /v1/models/{id}/story`, `GET /v1/me/models/{id}/story`,
  `POST /v1/models/{id}/story/pictures` (five per story, PNG, JPEG or WebP),
  `POST /v1/pictures/{id}/check` (G10), `PATCH /v1/versions/{id}` for the note. [community, models]
- Admin: posts (list, read a draft, save, publish, unpublish, pictures), stories (list, feature,
  unfeature, approve and remove a held edit), announcements (list, publish, disable), Notify
  (count an audience, send as one `INSERT ... SELECT`, the log with recipients and reads), picks
  (pin under G20, reorder, unpin). [community, platform, notifications, matches]
- Web's proxy config adds the `media-check` subrequest for `pictures/` keys.

## 5. Cutover

Production rebuilds once, when the step 1 image deploys. Before anything stops, run on production:

```sql
SELECT map_id FROM season_maps WHERE map_id !~ '^[a-z]+-[a-z]+-[0-9]+p-[0-9]+h$';
SELECT slug FROM seasons WHERE closed_at IS NOT NULL;
```

The first list keeps `null` board fields after the restore (G21); the second is what the podium
backfill covers (G22). Then follow the proposal's five steps, with the one-off script in
`scripts/` filling `margin` and `upset` for past rated matches, the board fields, and
`season_podium` for each closed season, without medal notifications. Step 5's rating-chain check
reads `ratings.matches_played` against `max(rating_events.seq)`, which CLAUDE.md says a restore must
keep.

## 6. What stays out

No new clock. No push delivery. No `opened` state on a notification. No page per board. No editing
of comments. Retention of `watch_events` and `audit_log` joins the README's *Known gaps* in step 1.
