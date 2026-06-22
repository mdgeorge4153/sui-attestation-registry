#!/usr/bin/env bash
# End-to-end demo, composed from the CLI ops in scripts/ops/ (create-box,
# attest-audit, revoke-audit) plus a few inline `sui client ptb` calls. Replaces
# the old TS demo (ts/demo/demo.ts) — every on-chain action here is a plain CLI
# move-call a user could run by hand.
#
# Scenario (mirrors DEMO-SCENARIO.md):
#   - create boxes for the dependency and the subject (which depends on it)
#   - audit the dependency (Audit, score 90; revoked at the end)
#   - audit the subject with AuditV2 (score 95; the live signal)
#   - audit the subject with v1 Audit (score 88; revoked at the end)
#   - attest_untrusted + attest_internal_note on the subject (both filtered out
#     by a trust consumer)
#   - revoke the dependency audit and the subject's v1 audit
#   - write demo-ids.json for the MVR seeder
#
# Requires: REGISTRY_ID env; packages test-published (Pub.localnet.toml); the
# active sui client address funded and holding the AuditAdminCap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPS="$REPO_ROOT/scripts/ops"
SUI="${SUI:-sui}"
RPC="${RPC:-http://127.0.0.1:9000}"
PUBFILE="${PUBFILE:-$REPO_ROOT/Pub.localnet.toml}"
REGISTRY="${REGISTRY_ID:?REGISTRY_ID is required (printed by test-publish.sh)}"

# Read a field from the pubfile [[published]] block matching a package name.
# (Same logic as scripts/test-publish.sh's parse_pkg_field.)
parse_pkg_field() {
    python3 - "$PUBFILE" "$1" "$2" <<'PY'
import re, sys
pubfile, target, field = sys.argv[1], sys.argv[2], sys.argv[3]
for block in open(pubfile).read().split('[[published]]'):
    if '/' + target in block:
        m = re.search(field + r'\s*=\s*"([^"]+)"', block)
        if m:
            print(m.group(1)); break
PY
}

REGPKG=$(parse_pkg_field attestation_registry published-at)
AUDIT=$(parse_pkg_field audit_example published-at)      # v2/latest id (has audit + audit_v2)
AUDIT_ORIG=$(parse_pkg_field audit_example original-id)  # v1 id — defines Audit + AuditAdminCap
DEP=$(parse_pkg_field dependency_example published-at)
SUBJ=$(parse_pkg_field subject_example published-at)
UNTRUSTED=$(parse_pkg_field untrusted_example published-at)

# The AuditAdminCap (its type is defined in the original audit id) was
# transferred to the publisher at publish; find it among the active address's
# owned objects.
ADDR=$("$SUI" client active-address)
CAP=$(curl -s "$RPC" -H 'Content-Type: application/json' -d "{
  \"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"suix_getOwnedObjects\",
  \"params\":[\"$ADDR\",{\"filter\":{\"StructType\":\"$AUDIT_ORIG::audit::AuditAdminCap\"}}]}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['data'][0]['data']['objectId'])")

echo "registry:    $REGISTRY"
echo "audit pkg:   $AUDIT (orig $AUDIT_ORIG)"
echo "admin cap:   $CAP"

echo "▶ create boxes (dependency + subject)"
DEP_BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$DEP")
SUBJ_BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$SUBJ")
echo "  dependency active box: $DEP_BOX"
echo "  subject active box:    $SUBJ_BOX"

echo "▶ attest_audit on dependency (score 90, will be revoked)"
DEP_AUDIT=$(bash "$OPS/attest-audit.sh" "$AUDIT" "$CAP" "$DEP_BOX" 90 "https://audits.example.com/dependency-v1.pdf")
echo "  $DEP_AUDIT"

echo "▶ attest_audit_v2 on subject (score 95, the live signal)"
v2_out=$("$SUI" client ptb \
    --move-call "$AUDIT::audit_v2::attest_audit_v2" "@$CAP" "@$SUBJ_BOX" 95 '"https://audits.example.com/subject-v1.pdf"' \
    --gas-budget 100000000 --json)
SUBJ_AUDIT_V2=$(printf '%s' "$v2_out" | python3 -c '
import json,sys
for c in json.load(sys.stdin).get("objectChanges",[]):
    if c.get("type")=="created" and "::audit_v2::AuditV2>" in c.get("objectType",""):
        print(c["objectId"]); break
')
echo "  $SUBJ_AUDIT_V2"

echo "▶ attest_audit on subject (score 88, will be revoked)"
SUBJ_AUDIT_V1=$(bash "$OPS/attest-audit.sh" "$AUDIT" "$CAP" "$SUBJ_BOX" 88 "https://audits.example.com/subject-v1.pdf")
echo "  $SUBJ_AUDIT_V1"

echo "▶ attest_untrusted + attest_internal_note on subject (both filtered out)"
"$SUI" client ptb \
    --move-call "$UNTRUSTED::untrusted::attest_untrusted" "@$SUBJ_BOX" '"not whitelisted"' \
    --move-call "$AUDIT::audit_v2::attest_internal_note" "@$SUBJ_BOX" '"no Display registered"' \
    --gas-budget 100000000 >/dev/null

echo "▶ revoke the dependency audit and the subject's v1 audit"
bash "$OPS/revoke-audit.sh" "$AUDIT" "$CAP" "$DEP_BOX" "$DEP_AUDIT"
bash "$OPS/revoke-audit.sh" "$AUDIT" "$CAP" "$SUBJ_BOX" "$SUBJ_AUDIT_V1"

# Hand-off for the MVR Postgres seeder.
DEMO_IDS="$REPO_ROOT/demo-ids.json"
REGISTRY="$REGISTRY" REGPKG="$REGPKG" SUBJ="$SUBJ" DEP="$DEP" \
AUDIT_ORIG="$AUDIT_ORIG" AUDIT="$AUDIT" DEP_AUDIT="$DEP_AUDIT" SUBJ_AUDIT_V2="$SUBJ_AUDIT_V2" \
python3 - "$DEMO_IDS" <<'PY'
import json, os, sys
json.dump({
    "registryId": os.environ["REGISTRY"],
    "attestationRegistryPkg": os.environ["REGPKG"],
    "subjects": {"subject": os.environ["SUBJ"], "dependency": os.environ["DEP"]},
    "trustedAttestors": [
        {"name": "audit_example",
         "originalId": os.environ["AUDIT_ORIG"],
         "latestId": os.environ["AUDIT"]},
    ],
    "createdAttestations": {
        "dependencyAudit": os.environ["DEP_AUDIT"],
        "subjectAuditV2": os.environ["SUBJ_AUDIT_V2"],
    },
}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
PY
echo "▶ wrote $DEMO_IDS"
