import { Transaction, type TransactionObjectArgument } from '@mysten/sui/transactions';

/**
 * Append `audit_example::audit::attest_audit(registry, subject, score)` to
 * `tx`. Returns the `RevocationCap<Audit>` move-call result so the caller
 * can route it (transfer to sender, store in shared state, etc.).
 */
export function attestAuditTx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    registryId: string;
    subject: string;
    score: number;
    reportUrl: string;
  },
): TransactionObjectArgument {
  const [cap] = tx.moveCall({
    target: `${args.auditExamplePkg}::audit::attest_audit`,
    arguments: [
      tx.object(args.registryId),
      tx.pure.id(args.subject),
      tx.pure.u8(args.score),
      tx.pure.string(args.reportUrl),
    ],
  });
  return cap!;
}

/**
 * Append `audit_example::audit_v2::attest_audit_v2(registry, subject, score,
 * report_url, requires)` to `tx`. `requires` is the list of attestation ids
 * this audit is conditional on (the `requires` convention). Returns the
 * `RevocationCap<AuditV2>` move-call result.
 *
 * `auditExamplePkg` must be the *upgraded* (v2) package id, since that is
 * where the `audit_v2` module is defined.
 */
export function attestAuditV2Tx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    registryId: string;
    subject: string;
    score: number;
    reportUrl: string;
    requires: string[];
  },
): TransactionObjectArgument {
  const [cap] = tx.moveCall({
    target: `${args.auditExamplePkg}::audit_v2::attest_audit_v2`,
    arguments: [
      tx.object(args.registryId),
      tx.pure.id(args.subject),
      tx.pure.u8(args.score),
      tx.pure.string(args.reportUrl),
      // `vector<ID>` is BCS-identical to `vector<address>`.
      tx.pure.vector('address', args.requires),
    ],
  });
  return cap!;
}

/**
 * Fully-qualified Move type for `Attestation<Audit>`. Pass audit_example's
 * *original* id as `auditExamplePkg` — the v1 `Audit` type keeps the original
 * id across the upgrade.
 */
export function auditAttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.auditExamplePkg}::audit::Audit>`;
}

/**
 * Fully-qualified Move type for `Attestation<AuditV2>`. Pass audit_example's
 * *upgraded* (v2) id as `auditExamplePkg` — `AuditV2` is defined in the
 * upgrade, so its defining id is the v2 id.
 */
export function auditV2AttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.auditExamplePkg}::audit_v2::AuditV2>`;
}
