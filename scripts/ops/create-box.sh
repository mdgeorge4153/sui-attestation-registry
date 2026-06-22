#!/usr/bin/env bash
# Create a subject's two boxes (active + revoked) and echo the ACTIVE box's
# object id (the one whose BoxKey.revoked is false — that's where attestations
# go). A reusable CLI op: plain `sui client ptb` over create_box.
#
# Usage: create-box.sh <registry-pkg> <registry-id> <subject-id>
set -euo pipefail
REGPKG=$1; REGISTRY=$2; SUBJECT=$3
SUI="${SUI:-sui}"

out=$("$SUI" client ptb \
    --move-call "$REGPKG::attestation_registry::create_box" "@$REGISTRY" "@$SUBJECT" \
    --gas-budget 100000000 --json)

tmp=$(mktemp); printf '%s' "$out" > "$tmp"
python3 - "$SUI" "$tmp" <<'PY'
import json, subprocess, sys
sui, tmp = sys.argv[1], sys.argv[2]
created = json.load(open(tmp)).get("objectChanges", [])
boxes = [c["objectId"] for c in created
         if c.get("type") == "created"
         and c.get("objectType", "").endswith("::attestation_registry::Box")]
for b in boxes:
    o = json.loads(subprocess.run([sui, "client", "object", b, "--json"],
                                  capture_output=True, text=True).stdout)
    content = o.get("content", {})
    fields = content.get("fields", content)   # some CLI versions nest under .fields
    key = fields.get("key", {})
    revoked = key.get("revoked", key.get("fields", {}).get("revoked"))
    if revoked is False:
        print(b); break
else:
    sys.exit("create-box: could not identify the active box among %r" % boxes)
PY
rm -f "$tmp"
