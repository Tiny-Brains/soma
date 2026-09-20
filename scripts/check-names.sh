#!/usr/bin/env bash
# THE NAMES ARE THE ORGANISING SYSTEM, so they are checked rather than remembered.
#
#   ./scripts/check-names.sh          (scripts/check-defs.sh runs it too)
#
# Orion 1.9.0 has exactly one organising field -- `tags: string[]` -- and `?tag=` is an EXACT,
# SINGLE-TAG match: the query is built as LIKE '%"<tag>"%', so there is no prefix match, no
# wildcard and no AND. There is also no name, id or description search on any list page. The tag
# filter IS the navigation, which is why what a definition is tagged is worth a check.
#
# WHAT MAKES THIS MORE THAN A SPELLING CHECK: the surface is DERIVED from the definition -- from
# its protocol, its route and how its workflow refuses -- and compared with what it claims. A tag
# cannot drift from what the channel actually does, because nobody writes the truth twice.
#
# No database, no stack, no Docker: it reads the set and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, pathlib, sys

PACKAGE = json.loads(pathlib.Path("shared/package.json").read_text())["package"]["name"]
SURFACES = ("pub", "user", "admin", "gate", "clock")

# The clocks split channel from workflow with a `-run` suffix; a REST route shares its id with the
# workflow it runs. `soma-runner-reap` is a cron that does neither -- it is a clock named and
# shaped as though it were a gate route, and it is the reason this rule is written down.
PAIRING_EXCEPTIONS = {"soma-runner-reap"}

errors, notes = [], []
def bad(p, msg): errors.append(f"{p}: {msg}")

def load(kind):
    return {p: json.loads(p.read_text()) for p in sorted(pathlib.Path(kind).glob("*.json"))}

channels, workflows, connectors = load("channels"), load("workflows"), load("connectors")
wf_by_id = {d["workflow_id"]: (p, d) for p, d in workflows.items()}

def steps(tasks):
    """Every task, descending into groups. A walk that does not is a walk that silently skips
    most of a clock's statements, since group_runs() folds consecutive tasks into groups."""
    for t in tasks:
        if "$each" in t:
            for v in t.values():
                if isinstance(v, dict) and "id" in v:
                    yield v
                    yield from steps(v.get("tasks", []))
            continue
        yield t
        yield from steps(t.get("tasks", []))

def refuses_non_admin(wf):
    """The admin surface, as the workflow actually enforces it.

    NOT `constants.admin_identity`: soma-admin-check reads the live session inline, on purpose,
    so that reference misses it. NOT the string `admin_only` either -- the notification-settings
    PATCH refuses the `admin` CATEGORY to a competitor and is a competitor's route. What is the
    admin surface and nothing else is the refusal CONDITION: this row's role is not admin."""
    def hunt(node):
        if isinstance(node, list):
            return any(hunt(x) for x in node)
        if not isinstance(node, dict):
            return False
        args = node.get("!=")
        if isinstance(args, list) and len(args) == 2:
            lhs, rhs = args
            if isinstance(lhs, dict) and str(lhs.get("var", "")).endswith("role") and rhs == "admin":
                return True
        return any(hunt(v) for v in node.values())
    return hunt(wf.get("tasks", []))

def derive(ch):
    """The surface this definition already is. THE ORDER IS LOAD-BEARING.

    The gate test runs before the auth test because `/v1/runner/token` declares no auth -- a key
    is exchanged for a token, so there is nothing to present yet -- and would read as public. The
    trailing slash is load-bearing too: `/v1/runner-keys` and `/v1/runners` are admin routes."""
    if ch.get("protocol") == "cron":
        return "clock"
    if ch.get("route_pattern", "").startswith("/v1/runner/"):
        return "gate"
    ref = ((ch.get("config") or {}).get("auth") or {}).get("$from")
    if ref is None:
        return "pub"
    if ref == "constants.runner_auth":
        return "gate"
    if ref == "constants.session_auth":
        e = wf_by_id.get(ch["workflow_id"])
        return "admin" if e and refuses_non_admin(e[1]) else "user"
    return f"<unknown auth {ref}>"

census = {}
for p, ch in channels.items():
    cid = ch["channel_id"]
    if p.name != cid + ".json":
        bad(p, f"the file name must be the id: {cid}.json")
    if ch.get("name") != cid:
        bad(p, f"name must equal the id ({cid!r}), not {ch.get('name')!r}")
    surface = derive(ch)
    if surface not in SURFACES:
        bad(p, f"the surface cannot be derived: {surface}")
        continue
    census[surface] = census.get(surface, 0) + 1

    want = cid + "-run" if surface == "clock" else cid
    if ch["workflow_id"] != want:
        if cid in PAIRING_EXCEPTIONS:
            notes.append(f"{p}: workflow_id is {ch['workflow_id']!r}, not {want!r}")
        else:
            bad(p, f"workflow_id should be {want!r}, not {ch['workflow_id']!r}")
    e = wf_by_id.get(ch["workflow_id"])
    if e is None:
        bad(p, f"names workflow {ch['workflow_id']!r}, which is not in workflows/")
    else:
        wp, wf = e
        if wp.name != wf["workflow_id"] + ".json":
            bad(wp, f"the file name must be the id: {wf['workflow_id']}.json")
        # A prose name is a decision: the id is in the url, the logs and the sql/ filenames, and
        # the list column is the one place a route can say what it is for.
        if wf.get("name") == wf["workflow_id"]:
            bad(wp, "name repeats the id; a workflow's name is prose")

routed = {ch["workflow_id"] for ch in channels.values()}
for wid in sorted(set(wf_by_id) - routed):
    bad(wf_by_id[wid][0], "no channel routes to it")

for p, cn in connectors.items():
    if p.name != cn["id"] + ".json":
        bad(p, f"the file name must be the id: {cn['id']}.json")
    if cn.get("name") != cn["id"]:
        bad(p, f"name must equal the id ({cn['id']!r}), not {cn.get('name')!r}")

# ---------------------------------------------------------------- tags
for kind, docs in (("channel", channels), ("workflow", workflows), ("connector", connectors)):
    for p, d in docs.items():
        if d.get("tags") != [f"pkg:{PACKAGE}"]:
            bad(p, f'tags must be ["pkg:{PACKAGE}"], not {json.dumps(d.get("tags"))}')

# ---------------------------------------------------------------- the sql/ directory
refs = {}
for p, wf in workflows.items():
    for t in steps(wf.get("tasks", [])):
        q = ((t.get("function") or {}).get("input") or {}).get("query")
        if isinstance(q, dict) and "$sql" in q:
            refs.setdefault(pathlib.PurePosixPath(q["$sql"]).name, []).append((wf["workflow_id"], t["id"]))
on_disk = {f.name for f in pathlib.Path("sql").glob("*.sql")}
for f in sorted(on_disk - set(refs)):
    bad(pathlib.Path("sql") / f, "no task names it")
for f in sorted(set(refs) - on_disk):
    bad(pathlib.Path("sql") / f, "a task names it but it is not on disk")
for f, sites in sorted(refs.items()):
    if "-shared-" in f:
        if len(sites) < 2:
            bad(pathlib.Path("sql") / f, "is named shared but only one task uses it")
        continue
    if len(sites) > 1:
        bad(pathlib.Path("sql") / f, f"{len(sites)} tasks share it, so its name carries -shared-")
        continue
    wid, tid = sites[0]
    if f != f"{wid}-{tid}.sql":
        bad(pathlib.Path("sql") / f, f"should be {wid}-{tid}.sql")

for n in notes:
    print(f"  note: {n}", file=sys.stderr)
for e in errors:
    print(f"  {e}", file=sys.stderr)
if errors:
    sys.exit(f"{len(errors)} naming error(s)")
print("  " + ", ".join(f"{s} {census.get(s, 0)}" for s in SURFACES)
      + f"; {len(connectors)} connectors, {len(on_disk)} statements")
PY
