# `auditor` — a reusable attestation schema

A reference schema package: a worked example of how a third-party attester
defines its own attestation type and controls who may issue and revoke it. Copy
it to stand up your own auditor identity — the demo does exactly that
(`demo/auditor_a`, `demo/auditor_b`).

## The schema

- **`Audit`** — a completed review: a score out of 100 and a link to the report.
- **`AuditAdminCap`** — the single authority that may issue or revoke this
  auditor's attestations (minted at publish, sent to the publisher). This is one
  authority-policy choice; the base registry prescribes none.

(The demo's `demo/auditor_a` layers an `AuditV2` upgrade on top of this schema to
illustrate schema evolution — that upgrade is demo-only, not part of the
reference.)

How the recorded attester is anchored to this package's identity, and how
consumers read and revoke attestations, is the registry's concern — see the
registry repo's `DESIGN.md`.

## Standing up your own auditor

A real auditor copies this package as a starting point. High level (TODO: expand
into a proper guide, possibly its own top-level doc):

- Register an MVR name for your package.
- Publish your own copy.
- Custody your `UpgradeCap` and the `AuditAdminCap` minted at publish.
- Replace this README with your auditing policy, or a link to your docs.

