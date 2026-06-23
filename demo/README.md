# Demo fixtures

Move packages that exist only to drive the local end-to-end demo
(`scripts/run-demo.sh`). Unlike `examples/`, nothing here is meant to be reused —
these are throwaway identities and subjects.

## Auditors

`auditor_a/` and `auditor_b/` are two **independently-published copies** of
`examples/auditor` (the reusable schema), with distinct package identities:

- **`auditor_a`** — in the demo's trust config (the "trusted" auditor). A copy of
  `examples/auditor` **plus** an added `AuditV2` upgrade — the schema-evolution
  illustration lives here, not in the reference.
- **`auditor_b`** — **not** in the trust config. A plain copy of
  `examples/auditor`. Its `Audit` records are identical in type to Auditor A's
  but anchored to a different package.

This is the core thing the demo shows: **trust is anchored to package identity,
not to the schema.** Two auditors emit the very same `Attestation<Audit>` type;
a consumer surfaces one and ignores the other purely by package address.

## Subjects

- **`dependency_example/`** — a package that gets audited; a dependency of
  `subject_example`.
- **`subject_example/`** — the package a viewer browses; depends on
  `dependency_example`.
