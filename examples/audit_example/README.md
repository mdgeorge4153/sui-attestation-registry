# Example Auditor

> Sample auditor package for the MVR attestation demo. Not a real audit firm.

**Example Auditor** is a Move security firm. We review Sui packages and publish
the results on-chain as `Attestation<Audit>` records anchored to this package's
identity, so anyone can verify — from bytecode, not a website — that an audit
came from us.

## What we attest

- **`Audit`** — a completed review, with a score out of 100 and a link to the
  full report.
- **`AuditV2`** — a richer schema added in a package upgrade: keeps the score
  and adds a link to the full report.

## Reading our attestations

Each audit is an `Attestation<Audit>` (or `Attestation<AuditV2>`) owned by the
audited subject's active `Box`. Any consumer can enumerate them directly:

```
getOwnedObjects(box_addr, filter={StructType:
  <registry-pkg>::attestation_registry::Attestation<<this-pkg>::audit::Audit>})
```

where `box_addr` is derived from `(registry_id, subject_id)`. A revoked audit
moves to the subject's revoked box, so it's read separately from the live set.
See the attestation-registry repo's `DESIGN.md` for the box-address derivation.

## Contact

- Reports: https://audits.example.com
- This is demo content; see the attestation-registry repo for how it's produced.
