# Demo fixtures

Move packages that exist only to drive the local end-to-end demo
(`scripts/run-demo.sh`). Unlike `examples/`, nothing here is meant to be reused —
these are throwaway identities and subjects.

## Auditors

`auditor_a/` and `auditor_b/` are two **independently-published copies** of
`examples/auditor` (the reusable schema), with the same source but distinct
package identities:

- **`auditor_a`** — in the demo's trust config (the "trusted" auditor). A full
  copy, including the `AuditV2` upgrade, which the demo applies to exercise the
  schema-evolution path.
- **`auditor_b`** — **not** in the trust config. A copy of the v1 schema only (it
  doesn't need `AuditV2` for the demo). Its `Audit` records are identical in type
  to Auditor A's but anchored to a different package.

This is the core thing the demo shows: **trust is anchored to package identity,
not to the schema.** Two auditors emit the very same `Attestation<Audit>` type;
a consumer surfaces one and ignores the other purely by package address.

## Subjects

- **`dependency_example/`** — a package that gets audited; a dependency of
  `subject_example`.
- **`subject_example/`** — the package a viewer browses; depends on
  `dependency_example`.
