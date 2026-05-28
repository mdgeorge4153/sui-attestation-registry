#!/usr/bin/env bash
# Test-publish all three Move packages against the active sui CLI network,
# sharing one ephemeral pubfile (Pub.<network>.toml at the repo root).
#
# After running, print the Registry shared-object id from
# attestation_registry's publish so it can be exported as REGISTRY_ID for
# the TS demo.
#
# Usage:
#   ./scripts/test-publish.sh                  # uses Pub.testnet.toml at repo root
#   ./scripts/test-publish.sh /custom/path.toml

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBFILE="${1:-$REPO_ROOT/Pub.testnet.toml}"
# Make absolute so test-publish from each package dir resolves to the same file.
PUBFILE="$(cd "$(dirname "$PUBFILE")" && pwd)/$(basename "$PUBFILE")"

echo "shared pubfile: $PUBFILE"

REGISTRY_ID=""

for pkg in attestation_registry audit_example vuln_example; do
    echo
    echo "▶ test-publish $pkg"
    out=$(cd "$REPO_ROOT/packages/$pkg" && sui client test-publish --pubfile-path "$PUBFILE" --json 2>&1)
    echo "  ok"
    # On attestation_registry's publish, extract the Registry shared object id.
    if [[ "$pkg" == "attestation_registry" ]]; then
        # Parse JSON for the created Registry object. Target type ends in
        # "::attestation_registry::Registry"; we accept any package prefix
        # since the test-publish address isn't known yet.
        REGISTRY_ID=$(printf '%s' "$out" | python3 -c "
import sys, json
data = sys.stdin.read()
# The CLI may print non-JSON preamble; find the first '{'.
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
    echo " run \`sui client object \$REGISTRY_ID\` against the publish tx digest"
    echo " to find it, then export it as REGISTRY_ID for the demo.)"
fi
