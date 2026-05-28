#!/usr/bin/env bash
# Test-publish all three Move packages against the active sui CLI network,
# sharing one ephemeral pubfile (Pub.<network>.toml at the repo root).
# After publishing, register the system Display for audit_example so the
# demo can render attestations.
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
# Make absolute so test-publish from each package dir resolves to the same file.
PUBFILE="$(cd "$(dirname "$PUBFILE")" && pwd)/$(basename "$PUBFILE")"

# Sui's system display registry is a well-known shared object.
DISPLAY_REGISTRY=0xd
GAS_BUDGET=100000000

echo "shared pubfile: $PUBFILE"

REGISTRY_ID=""

for pkg in attestation_registry audit_example vuln_example; do
    echo
    echo "▶ test-publish $pkg"
    out=$(cd "$REPO_ROOT/packages/$pkg" && sui client test-publish --pubfile-path "$PUBFILE" --json 2>&1)
    echo "  ok"
    # On attestation_registry's publish, extract the Registry shared object id.
    if [[ "$pkg" == "attestation_registry" ]]; then
        REGISTRY_ID=$(printf '%s' "$out" | python3 -c "
import sys, json
data = sys.stdin.read()
brace = data.find('{')
if brace >= 0:
    data = data[brace:]
r = json.loads(data)
for c in r.get('objectChanges', []):
    t = c.get('objectType', '')
    if t.endswith('::attestation_registry::Registry') and c.get('type') == 'created':
        print(c['objectId']); break
")
    fi
done

# Extract a package address from the pubfile by source-directory match.
parse_pkg() {
    python3 -c "
import re, sys
content = open(sys.argv[1]).read()
target = sys.argv[2]
for block in content.split('[[published]]'):
    if '/packages/' + target in block:
        m = re.search(r'published-at\s*=\s*\"([^\"]+)\"', block)
        if m:
            print(m.group(1)); break
" "$PUBFILE" "$1"
}

PKG_AUDIT=$(parse_pkg audit_example)
PKG_VULN=$(parse_pkg vuln_example)

echo
echo "▶ register_audit_display"
(cd "$REPO_ROOT/packages/audit_example" && \
    sui client call \
        --package "$PKG_AUDIT" --module audit --function register_audit_display \
        --args "$DISPLAY_REGISTRY" \
        --gas-budget "$GAS_BUDGET" >/dev/null)
echo "  ok"

echo
echo "▶ register_vuln_display"
(cd "$REPO_ROOT/packages/vuln_example" && \
    sui client call \
        --package "$PKG_VULN" --module vuln --function register_vuln_display \
        --args "$DISPLAY_REGISTRY" \
        --gas-budget "$GAS_BUDGET" >/dev/null)
echo "  ok"

echo
echo "✓ all three packages test-published and Displays registered"
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
