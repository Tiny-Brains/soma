#!/usr/bin/env python3
"""Every auth constant's `source.scheme` must end in a space.

Orion strips `auth.source.scheme` from the header as a LITERAL PREFIX. `"Bearer"` therefore
leaves a leading space on the token and the channel refuses every caller with a bare 401 -- the
same status as an absent, expired, revoked or wrong-audience token, and the same one several
smoke checks are asserting on purpose. Orion's own default carries the space; a hand-written
config is how it is lost, and it has been lost twice.

Run by check-defs.sh. Needs nothing but the file.
"""
import json
import pathlib
import sys

bad, seen = [], 0
for name, value in json.loads(pathlib.Path("shared/soma.json").read_text())["constants"].items():
    if not isinstance(value, dict):
        continue
    scheme = (value.get("source") or {}).get("scheme") if isinstance(value.get("source"), dict) else None
    if not isinstance(scheme, str):
        continue
    seen += 1
    # A scheme that is all spaces, or has none, or has two. `rstrip() + " "` is the only shape
    # that both strips cleanly and leaves the token intact.
    if scheme != scheme.rstrip() + " " or not scheme.strip():
        bad.append((name, scheme))

for name, scheme in bad:
    print(f"  {name}.source.scheme is {scheme!r} -- Orion strips it as a literal prefix, so it "
          f"must be {scheme.rstrip() + ' '!r}", file=sys.stderr)
if bad:
    sys.exit(1)
print(f"  {seen} auth constant(s) checked")
