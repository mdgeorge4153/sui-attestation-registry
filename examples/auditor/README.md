# `auditor` — a reusable attestation schema

A reference **schema package** for the attestation registry: a worked example of
how a third-party attester defines its own attestation type, anchors trust to its
package identity, and controls issuance and revocation. Copy this package to
stand up your own auditor identity — the demo does exactly that (see
`demo/auditor_a` and `demo/auditor_b`).

## The schema

- **`Audit`** — a completed review: a score out of 100 and a link to the report.
- **`AuditV2`** — a richer schema added in a package *upgrade*, demonstrating
  schema evolution: the upgraded package defines `AuditV2`, while
  `attester_of<AuditV2>()` still resolves to the original publish id.
- **`AuditAdminCap`** — the single authority that may issue or revoke this
  auditor's attestations. Minted once at publish and sent to the publisher. This
  is one authority-policy choice; the base registry prescribes none.

## How trust works

The attester recorded for every `Attestation<Audit>` is *this package's* original
publish address, bound at compile time — constructing the `Audit` payload is
restricted by Move to this package. So when you publish your own copy, your
attestations are anchored to *your* identity, and a consumer trusts you by
trusting your package address.

## Reading attestations

Each audit is an `Attestation<Audit>` (or `Attestation<AuditV2>`) owned by the
audited subject's active `Box`, enumerable via
`getOwnedObjects(box_addr, filter={StructType: …::Attestation<…::audit::Audit>})`
where `box_addr` derives from `(registry_id, subject_id)`. Revoked audits move to
the subject's revoked box, so they're read separately from the live set. See the
registry repo's `DESIGN.md` for the box-address derivation.
