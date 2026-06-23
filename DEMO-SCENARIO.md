# Demo scenario

The attestation data created by `scripts/demo.sh` (run via
`scripts/run-demo.sh`), for use with the MVR integration. Keep this in sync
with `demo.sh`.

## Packages

| Package | Role | Schemas |
|---|---|---|
| `attestation_registry` | the registry (shared `Registry` singleton) | — |
| `auditor_a` | trusted attester | `Audit` (v1); `AuditV2`, `InternalNote` (added in a v2 **upgrade**) |
| `auditor_b` | a second auditor (Auditor B), **not** in the trusted set | `Audit` (same source as `auditor_a`) |
| `dependency_example` | subject; dependency of `subject_example` | — |
| `subject_example` | the browsed subject; depends on `dependency_example` | — |

Trusted attesters (whitelist): `auditor_a` only. Its trust covers both its
original id (the `Audit` type) and its upgraded id (`AuditV2`) — the
schema-evolution case.

> Planned (fast-follow, not in this positive MVP): a `vuln_example` "negative"
> schema whose effective vulnerability disclosures propagate from a dependency
> to its dependents.

## Attestations

Every attestation is issued by `auditor_a` except where noted. Revocation
moves an attestation out of its subject's active box into the revoked box.

| Subject | Attestation | Status |
|---|---|---|
| `@demo/dependency` | Audit (score 90) | **Revoked** |
| `@demo/subject` | AuditV2 (score 95) | **Active** |
| `@demo/subject` | Audit (score 88, v1) | **Revoked** |
| `@demo/subject` | Audit (Auditor B, score 50) | **Active** |
| `@demo/subject` | InternalNote | **Active** |

## What a consumer sees

A consumer that trusts `auditor_a` but not `auditor_b` sees only the
**`AuditV2` (score 95)** attestation on `@demo/subject`: the v1 `Audit` is
revoked (in the revoked box), the Auditor B `Audit` is filtered out by attester
*identity* (same type, different package), and the `InternalNote` has no
registered Display. `@demo/dependency`'s only audit is revoked, so it shows no
live attestations at all.

Revoked attestations are still readable (from each subject's revoked box) — a
consumer typically lists them separately so they don't read as endorsements. The
auditor's own attestations are discoverable by querying its `Attestation<T>`
types across all subjects.
