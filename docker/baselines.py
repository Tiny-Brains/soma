#!/usr/bin/env python3
"""The platform's baselines, from a roster file. A step of `soma bootstrap`.

A baseline is a competitor the platform owns: a `baseline.<id>` account, one entry, and in the live
season one `active` version with two rating rows at the prior. They are the only opponents a trial
can seat, so a season without them admits nothing. This step makes the database hold exactly the
baselines the ROSTER names, and the models bucket hold their bytes.

THE ROSTER (TOML). Models are declared once and baselines point at them, so ten baselines can share
one artifact:

    [models.micro-bc]
    source = "https://raw.githubusercontent.com/Tiny-Brains/ants/<commit>/baselines/models/micro-bc"
    # or a directory: source = "models/micro-bc", relative to this file

    [[baselines]]
    id    = "micro-bc"     # PERMANENT: the account is baseline.micro-bc and its ratings hang off it
    name  = "micro-bc"     # what every ladder shows; change it whenever you like
    model = "micro-bc"

A source is a directory holding `model.onnx`, `manifest.json` and `metrics.json`: the layout
`ants/baselines/models/*` and `tinybrains check` both write. `metrics.json` carries the hashes and
the measurements admission would otherwise have produced, and both hashes are checked against the
bytes rather than trusted. `weights_hash` on a model pins it further, for a URL that could move.

WHICH FILE. $BASELINES_CONFIG, else /config/baselines.toml when one is mounted, else the roster this
image ships. `BASELINES_CONFIG=none` skips the step.

WHAT IT WILL AND WILL NOT CHANGE, and why:
  * `name` is display only -- the entry's name and the account's display name -- so a rename is an
    UPDATE and costs nothing.
  * `id` is the identity. A new id is a new baseline, rated from the prior.
  * A baseline's MODEL cannot change under it: its ratings describe the bytes it played. A roster
    that points an existing id at different weights is REFUSED; give it a new id.
  * A baseline the roster no longer names is REPORTED and left alone. Retiring one mid-season is a
    competitive decision, not a deploy step.
  * Versions exist only in a LIVE season. With none open, the accounts and entries are made and the
    versions follow on the first bootstrap after a season opens.
  * Every configured baseline's live version must have its two objects in the bucket, and a missing
    one is uploaded. A season carries its baselines forward as new version rows, whose keys are new
    and empty -- this is what fills them.
"""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import tomllib
import uuid

DEFAULT_ROSTER = "/pkg/soma/baselines.toml"
MOUNTED_ROSTER = "/config/baselines.toml"
TEMPLATE = "/etc/orion/soma.toml.tmpl"
FILES = ("model.onnx", "manifest.json", "metrics.json")
ID_SHAPE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?$")
HASH_SHAPE = re.compile(r"^sha256:[0-9a-f]{64}$")


def refuse(msg):
    print(f"REFUSED: {msg}", file=sys.stderr)
    sys.exit(1)


def env(name, default=None):
    v = os.environ.get(name, "")
    if v:
        return v
    if default is None:
        refuse(f"{name} is required by the baselines step")
    return default


# ---------------------------------------------------------------------------- the roster

def roster_path():
    p = os.environ.get("BASELINES_CONFIG", "")
    if p:
        return None if p == "none" else pathlib.Path(p)
    return pathlib.Path(MOUNTED_ROSTER if os.path.exists(MOUNTED_ROSTER) else DEFAULT_ROSTER)


def read_roster(path):
    try:
        doc = tomllib.loads(path.read_text())
    except FileNotFoundError:
        refuse(f"no roster at {path}")
    except tomllib.TOMLDecodeError as e:
        refuse(f"{path} is not valid TOML: {e}")

    unknown = set(doc) - {"models", "baselines"}
    if unknown:
        refuse(f"{path}: unknown top-level key(s) {sorted(unknown)} -- a roster has [models.*] and [[baselines]]")
    models = doc.get("models", {})
    baselines = doc.get("baselines", [])
    if not isinstance(models, dict) or not isinstance(baselines, list):
        refuse(f"{path}: `models` is a table of tables and `baselines` an array of tables")

    for key, m in models.items():
        extra = set(m) - {"source", "weights_hash"}
        if extra:
            refuse(f"[models.{key}]: unknown key(s) {sorted(extra)}")
        if not isinstance(m.get("source"), str) or not m["source"].strip():
            refuse(f"[models.{key}] needs a `source`: a URL or a directory holding {', '.join(FILES)}")
        if "weights_hash" in m and not HASH_SHAPE.match(str(m["weights_hash"])):
            refuse(f"[models.{key}].weights_hash must be sha256:<64 hex>")

    seen_ids, seen_names, used = {}, {}, set()
    for i, b in enumerate(baselines):
        where = f"baselines[{i}]"
        extra = set(b) - {"id", "name", "model"}
        if extra:
            refuse(f"{where}: unknown key(s) {sorted(extra)} -- a baseline is id, name and model")
        bid, name, model = b.get("id"), b.get("name"), b.get("model")
        if not isinstance(bid, str) or not ID_SHAPE.match(bid):
            refuse(f"{where}: id {bid!r} must be lowercase letters, digits and inner hyphens, at most 48")
        if not isinstance(name, str) or not name.strip() or len(name) > 64:
            refuse(f"{where} ({bid}): name must be 1 to 64 characters and not blank")
        if model not in models:
            refuse(f"{where} ({bid}): model {model!r} is not a [models.*] in this file")
        if bid in seen_ids:
            refuse(f"id {bid!r} appears twice ({seen_ids[bid]} and {where})")
        # Not a schema rule -- each baseline is its own account -- but two rows a ladder draws the
        # same way are two rows nobody can tell apart, which is the one thing a name is for.
        if name.strip().lower() in seen_names:
            refuse(f"name {name!r} appears twice ({seen_names[name.strip().lower()]} and {where})")
        seen_ids[bid] = where
        seen_names[name.strip().lower()] = where
        used.add(model)

    unused = sorted(set(models) - used)
    if unused:
        print(f"    note: [models.{'], ['.join(unused)}] declared and played by no baseline")
    return models, baselines


# ---------------------------------------------------------------------------- the artifacts

def sha256(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def download(pairs):
    """Every URL-sourced file in ONE curl process, so the connection is reused: a source is one host
    serving three files per model, and a slow connect paid once rather than per file is the
    difference between seconds and minutes on a network that reaches that host badly."""
    if not pairs:
        return
    args = ["curl", "-fsSL", "--retry", "5", "--retry-all-errors", "--connect-timeout", "20"]
    for url, out in pairs:
        args += ["-o", str(out), url]
    if subprocess.run(args, capture_output=True, text=True).returncode == 0:
        return
    for url, out in pairs:   # which one: curl does not say, over several transfers
        r = subprocess.run(["curl", "-fsSL", "--connect-timeout", "20", "-o", str(out), url],
                           capture_output=True, text=True)
        if r.returncode != 0:
            refuse(f"could not fetch {url}: {r.stderr.strip()}")


def stage(key, spec, base, into, pairs):
    """Where a model's three files come from: queued for download, or copied from a directory."""
    src = spec["source"].strip()
    out = into / key
    out.mkdir()
    if re.match(r"^https?://", src):
        pairs += [(f"{src.rstrip('/')}/{f}", out / f) for f in FILES]
    else:
        d = pathlib.Path(src)
        d = d if d.is_absolute() else base / d
        for f in FILES:
            if not (d / f).is_file():
                refuse(f"[models.{key}]: no {f} in {d} (is the directory mounted?)")
            (out / f).write_bytes((d / f).read_bytes())
    return out


def verify(key, spec, out):
    try:
        m = json.loads((out / "metrics.json").read_text())
    except ValueError as e:
        refuse(f"[models.{key}]: metrics.json is not JSON: {e}")
    need = ("weights_hash", "manifest_hash", "size_metric_bytes", "params", "infer_us_max")
    missing = [k for k in need if k not in m]
    if missing:
        refuse(f"[models.{key}]: metrics.json lacks {missing} -- re-export it with `tinybrains check`")

    # The hashes came from whatever measured these files. Checked, not trusted: a metrics.json left
    # beside a retrained model is the one way this goes wrong, and it would seed a row naming bytes
    # the bucket does not hold -- which every node would then refuse, a long way from the cause.
    for f, want in (("model.onnx", m["weights_hash"]), ("manifest.json", m["manifest_hash"])):
        got = sha256(out / f)
        if got != want:
            refuse(f"[models.{key}]: {f} hashes to {got} but metrics.json says {want}")
    if "weights_hash" in spec and spec["weights_hash"] != m["weights_hash"]:
        refuse(f"[models.{key}]: pinned to {spec['weights_hash']} but the source serves {m['weights_hash']}")

    # Bytes, decoded, and never read_text(): text mode folds CRLF to LF, and the schema's CHECK
    # hashes the stored text -- a manifest re-typed on the way in is one whose hash no longer holds.
    return {"dir": out, "metrics": m, "manifest": (out / "manifest.json").read_bytes().decode("utf-8")}


# ---------------------------------------------------------------------------- the database

DB = None


def psql(sql, **vars_):
    """Run a script and return its unaligned output. Values go in as psql variables, and a JSON
    document through a file and a backtick, which has no argument-length ceiling."""
    args = ["psql", DB, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]
    for k, v in vars_.items():
        args += ["-v", f"{k}={v}"]
    r = subprocess.run(args, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        refuse(f"the database refused the baselines step:\n{r.stderr.strip()}")
    return r.stdout.rstrip()


def state(game):
    out = psql(r"""
WITH live AS (
    SELECT s.id, s.number, s.weight_classes, s.rules
      FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = :'game' AND s.closed_at IS NULL
), mine AS (
    SELECT u.handle, e.id AS model_id, v.id AS version_id, v.weights_hash, v.weight_class::text AS weight_class
      FROM users u
      LEFT JOIN LATERAL (SELECT e.id FROM models e JOIN games g ON g.id = e.game_id AND g.slug = :'game'
                          WHERE e.owner_id = u.id AND e.retired_at IS NULL
                          ORDER BY e.created_at LIMIT 1) e ON true
      LEFT JOIN live ON true
      LEFT JOIN model_versions v ON v.model_id = e.id AND v.season_id = live.id
     WHERE u.role = 'baseline'
)
SELECT json_build_object(
    'game',  (SELECT count(*) FROM games WHERE slug = :'game'),
    'live',  (SELECT row_to_json(live) FROM live),
    'mine',  coalesce((SELECT json_agg(mine) FROM mine), '[]'::json))
""", game=game)
    return json.loads(out)


APPLY = r"""
\set roster `cat :'rfile'`
BEGIN;

CREATE TEMP TABLE roster ON COMMIT DROP AS
SELECT * FROM jsonb_to_recordset((:'roster')::jsonb) AS r (
    handle text, name text, version_id uuid, weight_class text, size_bytes bigint,
    param_count bigint, infer_us bigint, weights_hash text, manifest_hash text, manifest text,
    orion_version text);

-- The account. A baseline never signs in, so github_id stays null, and its handle is under the
-- `baseline.` prefix a GitHub login cannot mint. The display name follows the roster's name. The
-- conflict target is the expression users_handle_uniq was declared with, not the column.
INSERT INTO users (handle, role, display_name)
SELECT handle, 'baseline', name FROM roster
ON CONFLICT (lower(handle)) DO UPDATE SET display_name = EXCLUDED.display_name
 WHERE users.role = 'baseline' AND users.display_name IS DISTINCT FROM EXCLUDED.display_name;

-- One entry per baseline, named by the roster. The site draws a baseline as its ENTRY's name beside
-- the baseline mark, so this is the name a ladder shows, and renaming it is renaming the baseline.
INSERT INTO models (owner_id, game_id, name)
SELECT u.id, g.id, r.name
  FROM roster r
  JOIN users u ON lower(u.handle) = lower(r.handle) AND u.role = 'baseline'
  JOIN games g ON g.slug = :'game'
 WHERE NOT EXISTS (SELECT 1 FROM models e WHERE e.owner_id = u.id AND e.game_id = g.id AND e.retired_at IS NULL);

UPDATE models e SET name = r.name
  FROM roster r
  JOIN users u ON lower(u.handle) = lower(r.handle) AND u.role = 'baseline'
  JOIN games g ON g.slug = :'game'
 WHERE e.owner_id = u.id AND e.game_id = g.id AND e.retired_at IS NULL AND e.name IS DISTINCT FROM r.name;

-- A version in the live season for every baseline without one, at the id whose key the bytes were
-- already uploaded to, and two ratings at the prior -- the season's own, as season create seeds a
-- carried baseline, else [vars]' -- with their seq-0 events, so a new baseline starts in placement
-- like any promoted version (decision 28). The roster epoch moves in the same transaction, so pair
-- cannot see the new epoch before the rows it is about.
WITH live AS (
    SELECT s.id, s.rules FROM seasons s JOIN games g ON g.id = s.game_id
     WHERE g.slug = :'game' AND s.closed_at IS NULL
), entry AS (
    SELECT DISTINCT ON (u.id) r.*, e.id AS model_id, e.game_id
      FROM roster r
      JOIN users u ON lower(u.handle) = lower(r.handle) AND u.role = 'baseline'
      JOIN models e ON e.owner_id = u.id AND e.retired_at IS NULL
      JOIN games g ON g.id = e.game_id AND g.slug = :'game'
     ORDER BY u.id, e.created_at
), made AS (
    INSERT INTO model_versions (id, model_id, game_id, season_id, version, status, weight_class,
                                size_bytes, param_count, infer_us, weights_hash, manifest_hash,
                                manifest, orion_version)
    SELECT coalesce(entry.version_id, gen_random_uuid()), entry.model_id, entry.game_id, live.id,
           coalesce((SELECT max(x.version) FROM model_versions x WHERE x.model_id = entry.model_id), 0) + 1,
           'active', entry.weight_class::ladder, entry.size_bytes, entry.param_count, entry.infer_us,
           entry.weights_hash, entry.manifest_hash, entry.manifest, entry.orion_version
      FROM entry CROSS JOIN live
     WHERE NOT EXISTS (SELECT 1 FROM model_versions v WHERE v.model_id = entry.model_id AND v.season_id = live.id)
    RETURNING id, weight_class
), rated AS (
    INSERT INTO ratings (version_id, ladder, mu, sigma)
    SELECT made.id, l.ladder,
           coalesce((live.rules -> 'rating' ->> 'prior_mu')::float8, (:'mu')::float8),
           coalesce((live.rules -> 'rating' ->> 'prior_sigma')::float8, (:'sigma')::float8)
      FROM made CROSS JOIN live
      CROSS JOIN LATERAL (VALUES (made.weight_class), ('open'::ladder)) AS l (ladder)
    ON CONFLICT (version_id, ladder) DO NOTHING
    RETURNING version_id, ladder, mu, sigma
), events AS (
    INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
    SELECT version_id, ladder, 0, mu, sigma FROM rated
    ON CONFLICT (version_id, ladder, seq) DO NOTHING
    RETURNING 1
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
 WHERE c.key = 'roster' AND EXISTS (SELECT 1 FROM made);

-- Every configured baseline's live version and where its bytes belong, for the upload pass. Inside
-- the transaction, because `roster` is dropped at its commit.
SELECT coalesce(json_agg(json_build_object('handle', u.handle, 'key', v.artifact_key) ORDER BY u.handle), '[]')
  FROM roster r
  JOIN users u ON lower(u.handle) = lower(r.handle) AND u.role = 'baseline'
  JOIN models e ON e.owner_id = u.id
  JOIN model_versions v ON v.model_id = e.id
  JOIN seasons s ON s.id = v.season_id AND s.closed_at IS NULL
  JOIN games g ON g.id = s.game_id AND g.slug = :'game';

COMMIT;
"""


# ---------------------------------------------------------------------------- the bucket

S3 = None


EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def s3(method, key, body=None):
    """A signed request to the models bucket, by curl rather than anything of ours: the same
    SigV4 the connectors use, path-style, region `auto` as soma-models-internal declares it.

    x-amz-content-sha256 IS SENT BY HAND. S3 requires it, and the curl this image carries (7.88)
    neither sends nor signs it, so every request is `SignatureDoesNotMatch` -- a 403 that names the
    signature and not the missing header. A header given explicitly is one curl signs. It is the
    body's real hash, which also has the store check the upload arrived whole."""
    url = f"{S3['endpoint'].rstrip('/')}/{S3['bucket']}/{key}"
    payload = hashlib.sha256(body.read_bytes()).hexdigest() if body else EMPTY_SHA256
    args = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--retry", "3",
            "--aws-sigv4", f"aws:amz:{S3['region']}:s3", "--user", f"{S3['key']}:{S3['secret']}",
            "-H", f"x-amz-content-sha256: {payload}"]
    if method == "HEAD":
        args += ["-I"]
    else:
        args += ["-X", "PUT", "--data-binary", f"@{body}"]
    r = subprocess.run(args + [url], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()


def put(path, key):
    code = s3("PUT", key, path)
    if code != "200":
        refuse(f"PUT {S3['bucket']}/{key} answered {code} -- the models bucket, credentials and "
               f"MODELS_ENDPOINT must be what soma-models-internal uses")


def present(key):
    code = s3("HEAD", key)
    if code == "200":
        return True
    if code == "404":
        return False
    refuse(f"HEAD {S3['bucket']}/{key} answered {code} -- can this container reach MODELS_ENDPOINT?")


# ---------------------------------------------------------------------------- the step

def template_var(name):
    """A [vars] value out of the instance template, with a ${VAR:-default} resolved, so the
    prior is read from the one place the routes and the clocks read it and not typed twice."""
    m = re.search(rf"^{name}\s*=\s*(.+?)\s*$", pathlib.Path(TEMPLATE).read_text(), re.M)
    if not m:
        refuse(f"{TEMPLATE} has no {name}")
    v = m.group(1).strip().strip('"')
    sub = re.fullmatch(r"\$\{(\w+):-(.*)\}", v)
    return (os.environ.get(sub.group(1)) or sub.group(2)) if sub else v


def classify(size, classes):
    # The season's table, strictly ascending, first fit -- exactly as admission's classify does.
    for c in classes or []:
        if size <= int(c["max_bytes"]):
            return c["class"]
    return None


def main():
    global DB, S3
    path = roster_path()
    if path is None:
        print("==> baselines: BASELINES_CONFIG=none, skipped")
        return
    print(f"==> baselines from {path}")
    models, baselines = read_roster(path)
    if not baselines:
        print("    the roster names no baselines")

    DB = env("SOMA_DB_URL")
    game = env("GAME", "ants")
    S3 = {"endpoint": env("MODELS_ENDPOINT"), "bucket": env("MODELS_BUCKET"),
          "key": env("R2_ACCESS_KEY"), "secret": env("R2_SECRET_KEY"),
          "region": env("MODELS_REGION", "auto")}
    mu, sigma = template_var("prior_mu"), template_var("prior_sigma")
    orion = subprocess.run(["orion-server", "--version"], capture_output=True, text=True).stdout.split()
    orion_version = orion[1] if len(orion) > 1 else template_var("orion_version")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "art").mkdir()
        pairs, dirs = [], {}
        for k in sorted({b["model"] for b in baselines}):
            dirs[k] = stage(k, models[k], path.parent, tmp / "art", pairs)
        download(pairs)
        arts = {k: verify(k, models[k], d) for k, d in dirs.items()}

        handles = [f"baseline.{b['id']}" for b in baselines]
        st = state(game)
        if not st["game"]:
            refuse(f"no game {game!r} -- the cartridge step makes it, and runs first")
        live = st["live"]
        mine = {r["handle"].lower(): r for r in st["mine"]}

        rows, refused, planned = [], [], []
        for b in baselines:
            handle = f"baseline.{b['id']}"
            art = arts[b["model"]]
            m = art["metrics"]
            had = mine.get(handle.lower(), {})
            cls = None
            if live:
                cls = classify(int(m["size_metric_bytes"]), live["weight_classes"])
                if cls is None:
                    refused.append(f"{handle}: {m['size_metric_bytes']} bytes fits no weight class of season {live['number']}")
                    continue
                if m.get("class") and m["class"] != cls:
                    print(f"    note: {handle} measures {m['class']} by its own table and {cls} by season {live['number']}'s; the season's decides")
            if had.get("version_id"):
                # Its ratings describe the bytes it played. Moving them under it would rate one
                # model's results as another's, so a new model is a new id, as a competitor's
                # new weights are a new version.
                if had["weights_hash"] != m["weights_hash"]:
                    refused.append(f"{handle} plays {had['weights_hash'][:19]}... in season {live['number']}, "
                                   f"and the roster now gives it {m['weights_hash'][:19]}... -- a different model needs a new id")
                    continue
                vid = None
            else:
                vid = str(uuid.uuid4()) if live else None
                if vid:
                    planned.append((handle, art, vid))
            rows.append({"handle": handle, "name": b["name"].strip(), "version_id": vid,
                         "weight_class": cls, "size_bytes": int(m["size_metric_bytes"]),
                         "param_count": int(m["params"]), "infer_us": int(m["infer_us_max"]),
                         "weights_hash": m["weights_hash"], "manifest_hash": m["manifest_hash"],
                         "manifest": art["manifest"], "orion_version": orion_version,
                         "_art": b["model"]})
        if refused:
            refuse("the roster disagrees with the database:\n    " + "\n    ".join(refused))

        # Bytes before rows: the key is the version's id, chosen here, so a version never exists
        # without its object -- a row naming an empty key is a baseline every runner refuses.
        for handle, art, vid in planned:
            put(art["dir"] / "model.onnx", f"models/{vid}/model.onnx")
            put(art["dir"] / "manifest.json", f"models/{vid}/manifest.json")

        (tmp / "roster.json").write_text(json.dumps([{k: v for k, v in r.items() if k != "_art"} for r in rows]))
        keys = json.loads(psql(APPLY, rfile=str(tmp / "roster.json"), game=game, mu=mu, sigma=sigma) or "[]")

        # Every live version's two objects, whoever made the row. A season carries its baselines
        # forward as NEW version rows, and the key is the id, so a carried baseline's key is empty
        # until something fills it -- this pass is that something, on every bootstrap.
        by_handle = {r["handle"].lower(): arts[r["_art"]] for r in rows}
        filled = 0
        for k in keys:
            art = by_handle[k["handle"].lower()]
            for f, key in (("model.onnx", k["key"]), ("manifest.json", k["key"].rsplit("/", 1)[0] + "/manifest.json")):
                if not present(key):
                    put(art["dir"] / f, key)
                    filled += 1

        print(f"    {len(rows)} configured, {len(planned)} new version(s) with their objects, "
              f"{filled} missing object(s) restored")
        if not live:
            print("    no season is live: accounts and entries are in place, and their versions are made by the")
            print("    first bootstrap after a season opens")
        stale = sorted(h for h, r in mine.items() if h not in {x.lower() for x in handles} and r.get("version_id"))
        if stale:
            print(f"    not in the roster, left as they are: {', '.join(stale)}")

    print(psql(r"""
SELECT format('    %-28s %-24s %-6s %s', u.handle, e.name, v.weight_class, left(v.weights_hash, 19) || '...')
  FROM users u JOIN models e ON e.owner_id = u.id
  JOIN model_versions v ON v.model_id = e.id
  JOIN seasons s ON s.id = v.season_id AND s.closed_at IS NULL
  JOIN games g ON g.id = s.game_id AND g.slug = :'game'
 WHERE u.role = 'baseline' ORDER BY v.weight_class, u.handle
""", game=game))


if __name__ == "__main__":
    main()
