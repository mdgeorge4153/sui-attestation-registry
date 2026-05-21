import { useCurrentClient, useCurrentNetwork } from "@mysten/dapp-kit-react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Transaction } from "@mysten/sui/transactions";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { useState } from "react";
import { useKeypair } from "./KeypairContext";
import { AttestationCard } from "./AttestationCard";
import type { AttestationData } from "./AttestationCard";
import { ORIGINAL_PACKAGE_IDS, PACKAGE_IDS, REGISTRY_IDS } from "./dapp-kit";

/** Extract the full generic type argument from the on-chain type. */
function typeArgument(fullType: string): string {
  const match = fullType.match(/<(.+)>$/);
  return match ? match[1] : "";
}

export function MyAttestations() {
  const client = useCurrentClient() as SuiGrpcClient;
  const network = useCurrentNetwork();
  const { address, signAndExecute } = useKeypair();
  const queryClient = useQueryClient();
  const [revoking, setRevoking] = useState<string | null>(null);

  const originalPkg = ORIGINAL_PACKAGE_IDS[network];

  const { data: attestations, isPending } = useQuery({
    queryKey: ["my-attestations", address, network],
    queryFn: async () => {
      const result = await client.core.listOwnedObjects({
        owner: address!,
        type: `${originalPkg}::registry::Attestation`,
        include: { json: true },
        limit: 50,
      });
      return result.objects
        .filter((o) => o.json)
        .map((o) => ({
          id: o.objectId,
          type: o.type ?? "",
          fields: o.json as unknown as AttestationData["fields"],
        }));
    },
    enabled: !!address,
  });

  async function handleRevoke(attestation: AttestationData) {
    if (!address) return;
    setRevoking(attestation.id);
    try {
      const tx = new Transaction();
      tx.moveCall({
        target: `${PACKAGE_IDS[network]}::registry::revoke`,
        typeArguments: [typeArgument(attestation.type)],
        arguments: [
          tx.object(REGISTRY_IDS[network]),
          tx.object(attestation.id),
        ],
      });

      const result = await signAndExecute(tx, client);
      if (result.failed) {
        throw new Error(result.error ?? "Revoke failed");
      }
      await client.waitForTransaction({ digest: result.digest });
      await queryClient.invalidateQueries({ queryKey: ["my-attestations"] });
      await queryClient.invalidateQueries({ queryKey: ["attestations"] });
    } catch (e) {
      alert(e instanceof Error ? e.message : "Revoke failed");
    } finally {
      setRevoking(null);
    }
  }

  if (!address) return null;

  return (
    <div className="card">
      <h2>My Attestations</h2>
      {isPending && <p>Loading...</p>}
      {!isPending && (!attestations || attestations.length === 0) && (
        <p className="muted">You haven't created any attestations yet.</p>
      )}
      {attestations && attestations.length > 0 && (
        <div className="results">
          {attestations.map((a) => (
            <div key={a.id}>
              <AttestationCard attestation={a} />
              <button
                className="revoke-btn"
                onClick={() => handleRevoke(a)}
                disabled={revoking === a.id}
              >
                {revoking === a.id ? "Revoking..." : "Revoke"}
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
