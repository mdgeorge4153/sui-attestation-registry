import { Transaction, type TransactionArgument } from '@mysten/sui/transactions';

/**
 * Append `audit_example::audit::attest_audit(box, score)` to `tx`. Returns
 * the `RevocationCap<Audit>` move-call result so the caller can route it
 * (transfer to sender, store in shared state, etc.).
 */
export function attestAuditTx(
  tx: Transaction,
  args: { auditExamplePkg: string; boxId: string; score: number },
): TransactionArgument {
  const [cap] = tx.moveCall({
    target: `${args.auditExamplePkg}::audit::attest_audit`,
    arguments: [tx.object(args.boxId), tx.pure.u8(args.score)],
  });
  return cap!;
}

/**
 * Append `audit_example::audit::attest_audit_with_expiry(box, score, expires_at_ms)`
 * to `tx`. Returns the `RevocationCap<WithExpiry<Audit>>` move-call result.
 */
export function attestAuditWithExpiryTx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    boxId: string;
    score: number;
    expiresAtMs: bigint;
  },
): TransactionArgument {
  const [cap] = tx.moveCall({
    target: `${args.auditExamplePkg}::audit::attest_audit_with_expiry`,
    arguments: [
      tx.object(args.boxId),
      tx.pure.u8(args.score),
      tx.pure.u64(args.expiresAtMs),
    ],
  });
  return cap!;
}

/**
 * Fully-qualified Move type for `Attestation<Audit>` given the published
 * package addresses.
 */
export function auditAttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.auditExamplePkg}::audit::Audit>`;
}

/**
 * Fully-qualified Move type for `Attestation<WithExpiry<Audit>>`.
 */
export function auditWithExpiryAttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.attestationRegistryPkg}::with_expiry::WithExpiry<${args.auditExamplePkg}::audit::Audit>>`;
}
