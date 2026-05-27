import { Transaction } from '@mysten/sui/transactions';
import { deriveObjectID, fromHex, normalizeSuiAddress } from '@mysten/sui/utils';

/**
 * Compute the address of the per-subject `Box` derived from the given
 * `Registry`. Mirrors `derived_object::claim(registry, subject: ID)` on-chain.
 */
export function boxAddress(registryId: string, subject: string): string {
  const subjectBytes = fromHex(normalizeSuiAddress(subject).slice(2));
  return deriveObjectID(registryId, '0x2::object::ID', subjectBytes);
}

/**
 * Append a `create_box(registry, subject)` move call to `tx`.
 */
export function createBoxTx(
  tx: Transaction,
  args: { attestationRegistryPkg: string; registryId: string; subject: string },
): void {
  tx.moveCall({
    target: `${args.attestationRegistryPkg}::attestation_registry::create_box`,
    arguments: [tx.object(args.registryId), tx.pure.id(args.subject)],
  });
}
