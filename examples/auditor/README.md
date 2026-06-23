# `auditor` — a reusable attestation schema

A reference schema package: a worked example of how a third-party attester
defines its own attestation type and controls who may issue and revoke it. Copy
it to stand up your own auditor identity — the demo does exactly that
(`demo/auditor_a`, `demo/auditor_b`).

## The schema

- **`Audit`** — a completed review: a score out of 100 and a link to the report.
- **`AuditV2`** — a richer variant added in a package *upgrade*, demonstrating
  schema evolution.
- **`AuditAdminCap`** — the single authority that may issue or revoke this
  auditor's attestations (minted at publish, sent to the publisher). This is one
  authority-policy choice; the base registry prescribes none.

How the recorded attester is anchored to this package's identity, and how
consumers read and revoke attestations, is the registry's concern — see the
registry repo's `DESIGN.md`.
