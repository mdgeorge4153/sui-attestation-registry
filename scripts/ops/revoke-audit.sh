#!/usr/bin/env bash
# Revoke an Attestation<Audit> — moves it from the subject's active box to its
# revoked box. A reusable CLI op: plain `sui client ptb` over
# audit_example::revoke_audit. The attestation id is passed with `@` and the
# CLI resolves it as the `Receiving<Attestation<Audit>>` argument.
#
# Usage: revoke-audit.sh <audit-pkg> <admin-cap> <active-box> <attestation-id>
set -euo pipefail
AUDITPKG=$1; CAP=$2; BOX=$3; ATTESTATION=$4
SUI="${SUI:-sui}"

"$SUI" client ptb \
    --move-call "$AUDITPKG::audit::revoke_audit" "@$CAP" "@$BOX" "@$ATTESTATION" \
    --gas-budget 100000000 >/dev/null
