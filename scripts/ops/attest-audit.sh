#!/usr/bin/env bash
# Issue an Attestation<Audit> into a subject's active box and echo its object
# id. A reusable CLI op: plain `sui client ptb` over audit_example::attest_audit
# (admin-cap-gated). The auditor's AuditAdminCap gates both attest and revoke.
#
# Usage: attest-audit.sh <audit-pkg> <admin-cap> <active-box> <score-u8> <report-url>
set -euo pipefail
AUDITPKG=$1; CAP=$2; BOX=$3; SCORE=$4; URL=$5
SUI="${SUI:-sui}"

out=$("$SUI" client ptb \
    --move-call "$AUDITPKG::audit::attest_audit" "@$CAP" "@$BOX" "$SCORE" "\"$URL\"" \
    --gas-budget 100000000 --json)

printf '%s' "$out" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("objectChanges", []):
    if c.get("type") == "created" and "::attestation_registry::Attestation<" in c.get("objectType", ""):
        print(c["objectId"]); break
else:
    sys.exit("attest-audit: no Attestation created")
'
