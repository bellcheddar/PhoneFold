#!/usr/bin/env python3
"""Print `filename|bytes` for every matrix the forge manifest describes.

Split out of verify-bundle.sh because inlining it as a `python3 -c` string
inside a shell double-quoted block needed escaped quotes inside an f-string,
which is a syntax error. The shell loop then read nothing, verified nothing,
and printed OK for a deliberately truncated bundle.
"""
import json
import sys

with open(sys.argv[1]) as handle:
    manifest = json.load(handle)

entries = manifest.get("files") or []
if not entries:
    sys.exit("manifest lists no files")

for entry in entries:
    print("{}|{}".format(entry["file"], entry["bytes"]))
