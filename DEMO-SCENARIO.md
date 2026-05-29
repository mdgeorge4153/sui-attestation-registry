# Demo scenario

The attestation data created by `ts/demo.ts` (run via `scripts/run-demo.sh`),
for use with the MVR integration. Keep this in sync with `demo.ts`.

## Packages

| Package | Role | Schemas |
|---|---|---|
| `attestation_registry` | the registry (shared `Registry` singleton) | — |
| `audit_example` | trusted attester | `Audit` (v1); `AuditV2`, `InternalNote` (added in a v2 **upgrade**) |
| `vuln_example` | trusted attester | `Vulnerability` (negative, carries CVSS `severity`) |
| `untrusted_example` | attester **not** in the trusted set | `Untrusted` |
| `dependency_example` | subject; dependency of `subject_example` | — |
| `subject_example` | the browsed subject; depends on `dependency_example` | — |

Trusted attesters (whitelist): `audit_example`, `vuln_example`. The
`audit_example` trust covers both its original id (the `Audit` type) and its
upgraded id (`AuditV2`) — the schema-evolution case.

## Attestations

| Subject | Attestation | Attester | Severity | Status | Why |
|---|---|---|---|---|---|
| `@demo/dependency` | Audit | `audit_example` | — | **Revoked** | revoked at the end of the demo |
| `@demo/dependency` | Vulnerability | `vuln_example` | 7 · High | **Active** | **propagates** to `@demo/subject` |
| `@demo/subject` | Audit | `audit_example` | — | **Active** | score 88 |
| `@demo/subject` | AuditV2 | `audit_example` (v2) | — | **Ineffective** | `requires` the dependency's audit, which is revoked |
| `@demo/subject` | Vulnerability | `vuln_example` | 4 · Medium | **Active** | the package's own vuln |
| `@demo/subject` | Untrusted | `untrusted_example` | — | **Filtered out** | attester not whitelisted |
| `@demo/subject` | InternalNote | `audit_example` (v2) | — | **Filtered out** | no registered Display |

## Expected `@demo/subject` → Security tab

Attester display names come from the MVR trust config: `audit_example` →
"Example Auditor", `vuln_example` → "Example Security Scanner".

- Tab badge: **✓ 1** (the active Audit) and a **⚠ 2** warning pill colored by the
  max severity (High → red).
- **Vulnerabilities** (· 1 high, 1 medium — one severity-sorted list):
  - *Vulnerability disclosure* — **High (7.0)**, by Example Security Scanner,
    *in dependency `@demo/dependency`* (inherited);
  - *Vulnerability disclosure* — **Medium (4.0)**, by Example Security Scanner (own).
- **Audits**:
  - *Audit* — Active, by Example Auditor;
  - `Inactive: Example Auditor (Audit attestation (v2))` (the ineffective AuditV2).
- Not shown: the Untrusted and InternalNote attestations.
