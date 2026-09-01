# Orion gaps — what Soma needs

Tracking the [Orion](https://github.com/GoPlasmatic/Orion) features that would make Soma's workflow
package clean rather than assembled.

**Verified against source and against the linter**, not docs: `Orion` at `v1.5.1`, workspace
`version = "1.5.1"`, `dataflow-rs 3.9.0` / `datalogic-rs 5.4.0`. Claims cite a file and line in
`crates/orion-server/src/`, or a command whose output is quoted.

Soma is a small target on purpose: **eleven endpoints, one insert, nine reads, and a login.** The
match loop, TrueSkill and model admission belong to a separate game manager service that writes
`matches` and `ratings` directly. So this list is short, and all of it is about the *edges* of a
request — obtaining an identity, classifying a failure, shaping a response. **None of it is in the
data plane**, which already does everything Soma asks.

## Status at 1.5.1

**Three of the four blocking gaps closed in 1.5.0, and Soma has no blockers left.** G2 and G4 were
filed from this document and fixed under their own issue numbers; G3 was fixed as part of a wider
change that made nearly every task parameter JSONLogic. What remains is one narrowed gap and two
low-priority ones.

| | Gap | Status | Priority |
|---|---|---|---|
| G1 | Inbound OAuth2 authorization-code flow | still absent — but the assembled flow now **works** | low |
| G2 | Database error classification | **closed in 1.5.0** ([#297]) | — |
| G3 | Per-request headers on `http_call` | **closed in 1.5.0** (dataflow-rs 3.9) | — |
| G4 | More than one `Set-Cookie` per response | **closed in 1.5.0** ([#298]) | — |
| G5 | Keyset pagination | `skip` exists, keyset does not | low |
| G6 | Per-principal rate limiting | context is still `{client_ip, channel, headers}` | low |

The package is **pinned to 1.5.0 or newer** and says so loudly rather than degrading. On 1.4.0 the
same directory is four hard errors — one workflow, three channels — not a silent misbehaviour:

```
$ orion-server lint .          # 1.4.0
error: [schema.workflow] 'Complete GitHub sign-in' at tasks: config for function
       'http_call': invalid type: map, expected a string
error: [schema.channel] 'soma-auth-github-start' at channel.config: unknown field
       `cookies`, expected one of `mode`, `allowed_headers`, `error_bodies`
       … and the same for the callback and session-delete channels
.: 4 connector(s), 11 workflow(s), 11 channel(s) — 4 error(s)

$ orion-server lint . --deny-warnings          # 1.5.1
.: 4 connector(s), 11 workflow(s), 11 channel(s) — 0 error(s), 0 warning(s)
```

---

## G1 · Inbound OAuth2 authorization-code flow

**No longer blocking. Still absent as a feature.**

Nothing under `server/routes/` handles an inbound authorization-code callback in 1.5.1, and
`channel-config.md` still puts it out of scope — `auth.mode` is `api_key`, `hmac` or `jwt`, and
`connector/oauth.rs` remains what it always was: Orion *calling* an OAuth-protected API, not
completing a browser grant.

**What changed is that the assembled workaround now runs.** It was dead in 1.4 for one reason — the
callback could not attach a bearer token it had just obtained — and G3 fixed exactly that. Both
sign-in workflows now lint clean and express the whole flow declaratively:

| | |
|---|---|
| Start | `jwt_sign` a state token, shaped `302`, state set as a cookie · `soma-auth-github-start` |
| Callback | Compare cookie to query param, `jwt_verify` the state, exchange the code, `GET /user` with a computed `Authorization` header · `soma-auth-github-callback` |
| Session | `jwt_sign` a 30-day token the channels' `auth.mode: "jwt"` then verifies |
| Revocation | **Still nothing.** `DELETE /session` clears the cookie; the token stays valid to `exp` |

So what is left of G1 is genuinely optional, and one item of it is not:

- **PKCE is unrepresentable.** The signed state token stands in for it. For a confidential client
  with a fixed `redirect_uri` this is defensible; it is not what a native flow would do.
- **No revocation.** Sessions are stateless by necessity. A stolen token is good for 30 days. The
  fix does not need Orion — a `sessions` table and a `db_read` in each authed workflow would do it,
  at the cost of a query per request — so this is Soma's decision, not a gap.

Native inbound OAuth would still be better than either. It is no longer worth blocking on.

---

## G2 · Database error classification — **closed in 1.5.0**

Filed as [#297] from this document; fixed in the same cycle.

`metadata._orion_errors[0].code` now carries `integrity_unique`, `integrity_foreign_key`,
`integrity_not_null` or `integrity_check` (`errors.rs:542-546`), and an **uncaught** one answers
`409 CONFLICT` for the first two and `400 VALIDATION_ERROR` for the other two
(`errors.rs:676-684`). The classification is sqlx's own, so it means the same thing on every SQL
backend rather than being a SQLSTATE table Orion maintains. A related fix stopped `db_read`
stringifying its driver error before the failure type saw it.

**What this means for Soma: `POST /submissions` answers `409` with no workflow change at all.** The
one-in-flight and duplicate-release rules are partial unique indexes; a violation halts the run at
the insert and the platform states the conflict — "The request conflicts with an existing record".
`soma-submissions-create.json` therefore has no `continue_on_error` and no branch. That is the
whole fix, and writing one would only restate what the platform already says.

The two indexes remain indistinguishable to the workflow — the constraint name is deliberately not
surfaced, because sqlx populates it on PostgreSQL only and a branch that quietly stops matching
after a backend migration is worse than no branch. Soma does not care: `scope.md` asks for `409` in
both cases.

Integrity failures declare themselves non-retryable, so a stream of duplicate submissions cannot
trip the connector's circuit breaker.

---

## G3 · Per-request headers on `http_call` — **closed in 1.5.0**

The asymmetry named here — `path`/`path_logic` and `body`/`body_logic` paired, `headers` with no
counterpart — is gone, and by a wider route than this document proposed. dataflow-rs 3.9 made
**every** `http_call` parameter except `method` JSONLogic, so the pair spellings collapsed into one
field each and `headers` joined them: `template_at: &["*"]` on the field schema
(`engine/functions/http_call.rs:251-258`), meaning each header *value* is an expression.

The callback's identify step is now what it was always written as:

```json
"headers": { "authorization": { "cat": ["Bearer ", { "var": "temp_data.token.access_token" }] } }
```

`{"secret": …}` resolves in these fields too, and a computed `connector` is still refused — the
static name is what the dependency endpoint, the activation gate and the rename guard are built
from, so admitting one would mean teaching all five.

---

## G4 · More than one `Set-Cookie` per response — **closed in 1.5.0**

Filed as [#298]; fixed with more than was asked for. Both suggestions in the original entry landed:
a header value may now be an **array of strings**, sent once per element, *and* there is a
declarative `data._orion.response.cookies` block with `name`, `value`, `path`, `domain`, `max_age`,
`expires`, `same_site`, `http_only`, `secure`. Two supporting fixes came with it — `HeaderMap::insert`
was replacing rather than appending, so even a correctly produced pair collapsed to one, and the
bare `continue` that swallowed a non-string value now logs.

`response.cookies` is its own channel switch rather than an entry in `allowed_headers`, because that
list *replaces* the default one — gating cookies on it would force a channel setting a session
cookie to re-list `content-type` to keep serving JSON.

**Soma's three cookie channels now use the declared form** and hand-build no attribute strings. The
concrete thing this bought: the callback sets the session cookie and clears the spent
`soma_oauth_state` cookie **in the same response**, which the original entry called out as the price
Soma was paying — a single-use value lingering in the browser for its full 10-minute `Max-Age`.

A security fix arrived alongside: a shaped response that sets a cookie is **never cached**. A
channel that both set a `Set-Cookie` and enabled the response cache used to hand the first caller's
session cookie to everyone repeating that request for the TTL. Soma never enabled `cache` on an
authed channel, so it was not exposed — but the rule now holds regardless.

---

## G5 · Keyset pagination

**Low, unchanged in 1.5.** The dialect still has `skip` and not keyset (`config/query.rs`:
`default_limit: 100`, `max_limit: 1000`, `max_skip: 10_000`). Soma's leaderboard sorts on
`ratings.conservative`, a column in the *joined* table, so a correct cursor must encode
`(conservative, model_id)` and compare row-wise across the join.

Soma ships `OFFSET`, the cursor being the offset as a string — correct for a ladder of hundreds,
drifting if rows move between pages. It reaches Postgres through raw `db_read`, so `max_skip` does
not apply; a dialect user would hit a hard 10,000-row ceiling.

Worth noting that Orion's *own* admin API pages by keyset (`/traces?cursor=`), and
`design-notes.md` argues the case for it well. The capability exists in the product; it is the
portable dialect that does not expose it.

**Suggestion:** a `data_query` keyset option — sort key, page size, opaque cursor in and out.

---

## G6 · Per-principal rate limiting

**Low, unchanged in 1.5**, and now stated as a known limit in Orion's own docs
(`channel-config.md:426`): `rate_limit.key_logic`'s context is still

```rust
json!({ "client_ip": caller_identity, "channel": channel, "headers": headers })
```

`cache.key_logic` gained the same vocabulary in 1.5, and its documented example reads
`{"var": "metadata.auth.subject"}` — so the authenticated principal *is* available to the cache
guard. The rate-limit guard reads a different context and still cannot see it, which makes the
inconsistency sharper than it was.

Soma's quota (`platform.md` S3) is "submissions per day per competitor", and the competitor is
`metadata.auth.claims.sub`. The closest available key is the raw credential, which buckets per
*token*: two sessions, two buckets, and every re-login resets them.

**What would be enough:** `claims` in `rate_limit_context`, so `key_logic` can read
`{"var": "claims.sub"}` — the same value `cache.key_logic` already reads.

---

## Not gaps

Recorded because an earlier draft of Soma needed all four, and the scope reduction removed them.

| | Why it stopped mattering |
|---|---|
| **Transactions** | Soma's only write is a single-row insert. Promotion moved to the game manager. |
| **Multipart / binary bodies** | Submissions are a GitHub Release reference, not a 64 MiB ONNX upload. Soma moves no bytes. |
| **Cron / scheduled work** | The only periodic job was sweeping stale `testing` rows, which belongs to whoever promotes them. |
| **Heavy computation** | TrueSkill needs a Gaussian CDF and was never going to be JSONLogic. It left with the rating tables. |

The pattern is worth naming: **Orion fit Soma badly when Soma owned the match loop, and fits it well
now that Soma is a system of record.** Nine of Soma's eleven endpoints are a `db_read` and a `map`.

---

## Notes for whoever maintains this package

**N1 · `db_read` params fold `{"var": …}` and nothing else — this was a live bug in Soma.**
The leaderboard and match-history workflows wrote their defaults inline:

```json
"params": [ … { "or": [ { "var": "metadata.query.limit" }, 50 ] } ]
```

An `or` there is **never evaluated**. It is written through as a literal object and handed to
Postgres as a bind parameter, so `?limit=` unset did not mean 50 — it meant a JSON object where an
`int` belongs. Four occurrences across two workflows, every one of them on a paging parameter.

This is deliberate on Orion's side and now documented: SQL `params`, `jwt_sign.claims`,
`cache_write.value` and the Mongo document fields keep the `{"var": …}` fold precisely *because*
they carry `$set`, `$oid`, `$date` and `$ref`, and 3.9 strips one `$` from every key in a position
the engine evaluates. Making them expressions would silently rewrite stored definitions.

**1.5's linter is what found it** — `[logic.unresolvable]`, naming the exact param index and saying
what to do instead. Both workflows now compute defaults in a leading `map` task and reference the
result. Run `orion-server lint . --deny-warnings` before loading; this class of error passes every
other gate and shows up as wrong data.

**N2 · `body` and `body_logic` are not interchangeable under `body_format: "form"`.** Unfiled;
worth reporting upstream. The docs present `body_logic` as a pre-1.0 alias of `body` and `body` as
JSONLogic like everything else, but the authoring-time check reads the canonical key only
(`engine/functions/schema.rs:965` — `obj.get("body")`) and shape-checks it as a literal. So a
computed entry is refused under the modern spelling and accepted under the deprecated one:

```
$ orion-server lint body.json         # "body": {"a": {"var": "data.a"}}
error: [INVALID] body_format 'form' cannot encode 'a' (an object): entries must be
       scalars or arrays of scalars — form encoding has no canonical nesting

$ orion-server lint logic.json        # "body_logic": {"a": {"var": "data.a"}}
'logic.json' is valid.
```

The runtime is fine either way — in template mode `{"var": …}` evaluates to a string before
`encode_form` sees it. It is the static check that cannot tell a JSONLogic node from nesting. The
comment above it says a `body_logic` body "only exists per message and gets that check at request
time", which was true when the two keys meant different things and is not now.

**Soma's OAuth token exchange therefore keeps `body_logic` deliberately.** Renaming it to `body` —
the obvious modernisation, and the one this upgrade started by making — breaks the package. Leave
it until the check learns to skip expression nodes.

**N3 · A computed `http_call` header cannot be asserted offline.** The dry-run call recorder
stores `connector`, `method`, `path` and `body` (`engine/functions/stub.rs:482-487`) — not
`headers`. So the callback's whole flow is testable offline, and the one thing 1.5.0 newly made
possible in it is the one thing a regression case cannot pin:

```
"calls": { "http_call": [ { "task_id": "identify", "stub_target": "github-api",
                            "input": { "connector": "github-api", "method": "GET",
                                       "path": "/user", "body": null } } ] }
```

A wrong `Authorization` still passes. The task running at all is real evidence — on 1.4 it failed to
deserialize before executing — but it is weaker than the `expect_calls` assertion the feature
deserves. Recording the resolved headers alongside the resolved body would close it, and the
resolution already happens one call earlier in `run`.

**UUID generation exists.** `random` is a JSONLogic **operator**, not a task function
(`engine/operators.rs:494`). `{"random": ["uuid"]}` gives a v4, `{"random": ["uuid", "v7"]}` a
time-sortable v7, available on every expression surface. Soma lets Postgres default its primary
keys, but an id needed *before* the row exists is one `map` mapping away.

**`validation` takes `{logic, message}`, not `{path, logic, message}`.**

**Response-header allowlist replaces, not extends.** `response.allowed_headers` narrows as well as
widens, so a channel naming `["location"]` loses `content-type` from the allowlist. Soma's two
redirect channels rely on the `application/json` default, which is applied separately. Note this is
also why `response.cookies` is a separate boolean.

**`data_mounts` does not prepend to `route_pattern`.** The full request path, mount prefix included,
is matched against the pattern. Soma's channels therefore declare `/v1/...` in the pattern *and* set
`data_mounts = ["/v1"]`.

**`server.bind_addr` does not exist** — it is `host` and `port`. `server/orion.toml.example` carried
`bind_addr` and would have failed to parse at startup; fixed. `orion-server -c orion.toml
validate-config` catches this in a second and is worth a CI line.

[#296]: https://github.com/GoPlasmatic/Orion/issues/296
[#297]: https://github.com/GoPlasmatic/Orion/issues/297
[#298]: https://github.com/GoPlasmatic/Orion/issues/298
