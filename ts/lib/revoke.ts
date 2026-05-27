import { Transaction } from '@mysten/sui/transactions';

/**
 * Append the `borrow` + `revoke` PTB sequence to `tx`. The pair is required
 * because under TTO the attestation is owned-by-Box; `borrow` issues an
 * `AttestationBorrow` hot potato, and `revoke` is the only place (other than
 * `put_back`) that's allowed to discharge it.
 *
 * `attestationRef` is the on-chain (id, version, digest) of the attestation
 * being revoked — call `getAttestation` first to read these.
 *
 * `attestationType` is the fully-qualified Move type stored in the
 * attestation's payload — i.e. the `T` in `Attestation<T>`. For example, an
 * audit attestation uses `"0xAUD::audit::Audit"`.
 */
export function revokeTx(
  tx: Transaction,
  args: {
    attestationRegistryPkg: string;
    boxId: string;
    attestationRef: { objectId: string; version: string; digest: string };
    capId: string;
    attestationType: string;
  },
): void {
  const pkg = args.attestationRegistryPkg;
  const typeArgs = [args.attestationType];
  const rcv = tx.receivingRef(args.attestationRef);

  const [attestation, borrow] = tx.moveCall({
    target: `${pkg}::attestation_registry::borrow`,
    typeArguments: typeArgs,
    arguments: [tx.object(args.boxId), rcv],
  });

  tx.moveCall({
    target: `${pkg}::attestation_registry::revoke`,
    typeArguments: typeArgs,
    arguments: [
      tx.object(args.boxId),
      attestation!,
      tx.object(args.capId),
      borrow!,
    ],
  });
}
