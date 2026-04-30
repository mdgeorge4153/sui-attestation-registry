#!/usr/bin/env bash
# End-to-end demo: register Display, create one Attestation per Status variant,
# query each via JSON-RPC and print the rendered Display.
#
# Run from repo root after a successful `sui client test-publish` of both
# attestation_registry and audit_example. Reads package addresses from the
# workspace pubfile at ./Pub.testnet.toml.
#
# Usage: ./scripts/demo.sh

set -euo pipefail

PUBFILE="$(dirname "$0")/../Pub.testnet.toml"
RPC="https://fullnode.testnet.sui.io:443"
DISPLAY_REGISTRY="0xd"

# Subjects used per variant. Pass a suffix as the first arg when re-running to
# avoid colliding with prior attestations under the same (T, subject, attester).
SUFFIX="${1:-00}"
SUBJ_ACTIVE="0x0000000000000000000000000000000000000000000000000000000000${SUFFIX}c001"
SUBJ_EXPIRY="0x0000000000000000000000000000000000000000000000000000000000${SUFFIX}c002"
SUBJ_REVOKE="0x0000000000000000000000000000000000000000000000000000000000${SUFFIX}c003"

# A timestamp comfortably in the future for the ActiveUntil case.
EXPIRES_AT_MS=1893456000000

# Pull the two package addresses out of the pubfile by matching on the source
# directory.
extract_pkg() {
    local source_dir="$1"
    awk -v dir="$source_dir" '
        /^\[\[published\]\]/ { in_block = 1; src = ""; pub = "" }
        in_block && /^source / { src = $0 }
        in_block && /^published-at / { gsub(/"/, "", $3); pub = $3 }
        in_block && pub != "" && src ~ dir { print pub; exit }
    ' "$PUBFILE"
}

PKG_ATT=$(extract_pkg "attestation_registry")
PKG_AUDIT=$(extract_pkg "audit_example")
[[ -z "$PKG_ATT" || -z "$PKG_AUDIT" ]] && { echo "couldn't read pkg addresses from $PUBFILE" >&2; exit 1; }

# Look up the Registry shared object created by attestation_registry's init.
REG=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"suix_queryTransactionBlocks","params":[{"filter":{"FromAddress":"$(sui client active-address)"},"options":{"showObjectChanges":true}},null,20,true]}
EOF
)" "$RPC" | python3 -c "
import sys, json
target_type = '$PKG_ATT::attestation_registry::Registry'
r = json.load(sys.stdin)
for tx in r['result']['data']:
    for c in tx.get('objectChanges', []):
        if c.get('type') == 'created' and c.get('objectType') == target_type:
            print(c['objectId']); sys.exit(0)
")
[[ -z "$REG" ]] && { echo "couldn't find Registry on-chain — has attestation_registry been published?" >&2; exit 1; }

echo "package attestation_registry: $PKG_ATT"
echo "package audit_example:        $PKG_AUDIT"
echo "Registry:                     $REG"
echo

run_call() {
    local label="$1"; shift
    echo "▶ $label"
    local out; out=$(sui client call "$@" --gas-budget 100000000 2>&1 || true)
    echo "$out" | grep -E "Status: (Success|Failure)" | head -1 || echo "  (no Status line — likely aborted before execution; continuing)"
}

extract_shared_attestation() {
    sui client call "$@" --gas-budget 100000000 --json 2>/dev/null \
        | python3 -c "
import sys, json
r = json.load(sys.stdin)
for c in r.get('objectChanges', []):
    if c.get('type') == 'created' and c.get('owner', {}).get('Shared') is not None and 'Attestation' in c.get('objectType', ''):
        print(c['objectId']); sys.exit(0)
"
}

run_call "register_audit_display" \
    --package "$PKG_AUDIT" --module audit --function register_audit_display \
    --args "$DISPLAY_REGISTRY"

ATT_ACTIVE=$(extract_shared_attestation \
    --package "$PKG_AUDIT" --module audit --function attest_audit \
    --args "$REG" "$SUBJ_ACTIVE" 8)
echo "Active attestation:           $ATT_ACTIVE"

ATT_EXPIRY=$(extract_shared_attestation \
    --package "$PKG_AUDIT" --module audit --function attest_audit_with_expiry \
    --args "$REG" "$SUBJ_EXPIRY" 9 "$EXPIRES_AT_MS")
echo "ActiveUntil attestation:      $ATT_EXPIRY"

ATT_REVOKE=$(extract_shared_attestation \
    --package "$PKG_AUDIT" --module audit --function attest_audit \
    --args "$REG" "$SUBJ_REVOKE" 6)
echo "to-be-revoked attestation:    $ATT_REVOKE"

run_call "revoke" \
    --package "$PKG_ATT" --module attestation_registry --function revoke \
    --type-args "$PKG_AUDIT::audit::Audit" \
    --args "$ATT_REVOKE"

echo
echo "=== Display rendering ==="
for label in "Active::$ATT_ACTIVE" "ActiveUntil::$ATT_EXPIRY" "Revoked::$ATT_REVOKE"; do
    name="${label%%::*}"
    addr="${label##*::}"
    echo
    echo "--- $name [$addr] ---"
    curl -s -X POST -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sui_getObject\",\"params\":[\"$addr\",{\"showDisplay\":true,\"showContent\":true}]}" \
        "$RPC" | python3 -c "
import sys, json
r = json.load(sys.stdin)
d = r['result']['data']
print('display.data: ', json.dumps(d['display'].get('data'), indent=2))
err = d['display'].get('error')
if err: print('display.error:', err)
s = d['content']['fields']['status']
print('status variant:', s.get('variant'), 'fields:', s.get('fields'))
"
done
