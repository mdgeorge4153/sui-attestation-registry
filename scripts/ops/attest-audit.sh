#!/usr/bin/env bash
# Issue an Attestation<Audit> into a subject's active box and echo its id.
# Reusable CLI op over audit_example::attest_audit (admin-cap-gated); the
# auditor's AuditAdminCap gates both attest and revoke.
#
# Usage: attest-audit.sh <audit-pkg> <admin-cap> <active-box> <score-u8> <report-url>
set -euo pipefail
AUDITPKG=$1; CAP=$2; BOX=$3; SCORE=$4; URL=$5

sui client ptb \
    --move-call "$AUDITPKG::audit::attest_audit" "@$CAP" "@$BOX" "$SCORE" "\"$URL\"" \
    --gas-budget 100000000 --json \
  | jq -r '.objectChanges[] | select(.objectType | contains("::Attestation<")) | .objectId'
