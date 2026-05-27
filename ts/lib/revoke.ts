import { Transaction } from '@mysten/sui/transactions';

/**
 * Append `attestation_registry::revoke(box, cap, rcv, ctx)` to `tx`. The
 * registry handles receive + flip + transfer-back internally; the caller
 * just supplies the box, cap, receiving ref, and a type argument.
 */
export function revokeTx(
  tx: Transaction,
  args: {
    attestationRegistryPkg: string;
    boxId: string;
    capId: string;
    attestationRef: { objectId: string; version: string; digest: string };
    attestationType: string;
  },
): void {
  tx.moveCall({
    target: `${args.attestationRegistryPkg}::attestation_registry::revoke`,
    typeArguments: [args.attestationType],
    arguments: [
      tx.object(args.boxId),
      tx.object(args.capId),
      tx.receivingRef(args.attestationRef),
    ],
  });
}
