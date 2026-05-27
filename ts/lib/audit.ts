import { Transaction, type TransactionArgument } from '@mysten/sui/transactions';

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
  },
): TransactionArgument {
  const [cap] = tx.moveCall({
    target: `${args.auditExamplePkg}::audit::attest_audit`,
    arguments: [
      tx.object(args.registryId),
      tx.pure.id(args.subject),
      tx.pure.u8(args.score),
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
