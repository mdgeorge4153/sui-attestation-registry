#!/usr/bin/env bash
# Test-publish all three Move packages against the active sui CLI network,
# sharing one ephemeral pubfile (Pub.<network>.toml at the repo root).
# After publishing, register the system Display for audit_example and
# vuln_example so the demo can render attestations.
#
# Prints the Registry shared-object id from attestation_registry's publish
# so it can be exported as REGISTRY_ID for the TS demo.
#
# Usage:
#   ./scripts/test-publish.sh                  # uses Pub.testnet.toml at repo root
#   ./scripts/test-publish.sh /custom/path.toml

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBFILE="${1:-$REPO_ROOT/Pub.testnet.toml}"
PUBFILE="$(cd "$(dirname "$PUBFILE")" && pwd)/$(basename "$PUBFILE")"

# Sui's system display registry is a well-known shared object.
DISPLAY_REGISTRY=0xd
GAS_BUDGET=100000000

# Remove any prior pubfile so test-publish starts each package from a clean
# slate. Otherwise existing entries cause re-publish errors.
if [[ -f "$PUBFILE" ]]; then
    echo "removing prior pubfile: $PUBFILE"
    rm -f "$PUBFILE"
fi

echo "shared pubfile: $PUBFILE"

REGISTRY_ID=""

# Find the substring [start..end] of `data` that's a balanced JSON object,
# parse it, and dump it back. Tolerates non-JSON text around the JSON block
# (compiler warnings, status lines, etc.). On failure prints nothing.
extract_json() {
    python3 - "$1" <<'PY'
import sys, json
data = open(sys.argv[1]).read()
start = data.find('{')
end = data.rfind('}')
if start < 0 or end <= start:
    sys.exit(0)
try:
    json.dumps(json.loads(data[start:end+1]))
except Exception:
    sys.exit(0)
print(data[start:end+1])
PY
}

for pkg in attestation_registry audit_example vuln_example; do
    echo
    echo "▶ test-publish $pkg"
    json_out=$(mktemp)
    if ! (cd "$REPO_ROOT/packages/$pkg" \
            && sui client test-publish --build-env testnet --pubfile-path "$PUBFILE" --json) \
            > "$json_out" 2>&1; then
        echo "  FAILED. Output:"
        cat "$json_out"
        rm -f "$json_out"
        exit 1
    fi
    echo "  ok"
    if [[ "$pkg" == "attestation_registry" ]]; then
        json=$(extract_json "$json_out" || true)
        if [[ -n "$json" ]]; then
            REGISTRY_ID=$(python3 -c "
import json, sys
r = json.loads(sys.stdin.read())
for c in r.get('objectChanges', []):
    t = c.get('objectType', '')
    if t.endswith('::attestation_registry::Registry') and c.get('type') == 'created':
        print(c['objectId']); break
" <<<"$json")
        fi
    fi
    rm -f "$json_out"
done

# Extract a package address from the pubfile by source-directory match.
parse_pkg() {
    python3 - "$PUBFILE" "$1" <<'PY'
import re, sys
pubfile, target = sys.argv[1], sys.argv[2]
content = open(pubfile).read()
for block in content.split('[[published]]'):
    if '/packages/' + target in block:
        m = re.search(r'published-at\s*=\s*"([^"]+)"', block)
        if m:
            print(m.group(1)); break
PY
}

PKG_AUDIT=$(parse_pkg audit_example)
PKG_VULN=$(parse_pkg vuln_example)

if [[ -z "$PKG_AUDIT" ]] || [[ -z "$PKG_VULN" ]]; then
    echo "could not resolve package addresses from $PUBFILE — skipping display registration"
    echo "PKG_AUDIT=$PKG_AUDIT"
    echo "PKG_VULN=$PKG_VULN"
else
    echo
    echo "▶ register_audit_display"
    if ! (cd "$REPO_ROOT/packages/audit_example" && \
            sui client call \
                --package "$PKG_AUDIT" --module audit --function register_audit_display \
                --args "$DISPLAY_REGISTRY" \
                --gas-budget "$GAS_BUDGET" >/dev/null 2>&1); then
        echo "  FAILED (Display may already exist for Attestation<Audit>)"
    else
        echo "  ok"
    fi

    echo
    echo "▶ register_vuln_display"
    if ! (cd "$REPO_ROOT/packages/vuln_example" && \
            sui client call \
                --package "$PKG_VULN" --module vuln --function register_vuln_display \
                --args "$DISPLAY_REGISTRY" \
                --gas-budget "$GAS_BUDGET" >/dev/null 2>&1); then
        echo "  FAILED (Display may already exist for Attestation<Vulnerability>)"
    else
        echo "  ok"
    fi
fi

echo
echo "✓ all three packages test-published"
if [[ -n "$REGISTRY_ID" ]]; then
    echo
    echo "Registry shared object: $REGISTRY_ID"
    echo
    echo "Run the TS demo with:"
    echo "  REGISTRY_ID=$REGISTRY_ID pnpm --dir ts demo"
else
    echo
    echo "(couldn't extract Registry id from attestation_registry's publish output;"
    echo " look it up via the publish tx digest, then export it as REGISTRY_ID.)"
fi
