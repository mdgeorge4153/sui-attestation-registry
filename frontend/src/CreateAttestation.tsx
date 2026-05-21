import { useState } from "react";
import { useCurrentClient, useCurrentNetwork } from "@mysten/dapp-kit-react";
import { useQueryClient } from "@tanstack/react-query";
import { Transaction } from "@mysten/sui/transactions";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { useKeypair } from "./KeypairContext";
import { PACKAGE_IDS, REGISTRY_IDS } from "./dapp-kit";

type PayloadType = "AuditReport" | "SourceVerification";

export function CreateAttestation() {
  const client = useCurrentClient() as SuiGrpcClient;
  const network = useCurrentNetwork();
  const { address, signAndExecute } = useKeypair();
  const queryClient = useQueryClient();

  const [packageId, setPackageId] = useState("");
  const [payloadType, setPayloadType] = useState<PayloadType>("AuditReport");

  // AuditReport fields
  const [url, setUrl] = useState("");
  const [auditor, setAuditor] = useState("");

  // SourceVerification fields
  const [sourceHash, setSourceHash] = useState("");
  const [repoUrl, setRepoUrl] = useState("");
  const [revision, setRevision] = useState("");

  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [digest, setDigest] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!address) return;
    setIsPending(true);
    setError(null);
    setDigest(null);

    try {
      const tx = new Transaction();
      const pkg = PACKAGE_IDS[network];

      if (payloadType === "AuditReport") {
        const [payload] = tx.moveCall({
          target: `${pkg}::payloads::new_audit_report`,
          arguments: [tx.pure.string(url), tx.pure.string(auditor)],
        });
        tx.moveCall({
          target: `${pkg}::registry::attest_and_keep`,
          typeArguments: [`${pkg}::payloads::AuditReport`],
          arguments: [
            tx.object(REGISTRY_IDS[network]),
            tx.pure.address(packageId),
            payload,
          ],
        });
      } else {
        // Convert hex string to bytes
        const hashHex = sourceHash.replace(/^0x/, "");
        const hashBytes = Array.from(
          { length: hashHex.length / 2 },
          (_, i) => parseInt(hashHex.slice(i * 2, i * 2 + 2), 16),
        );
        const [payload] = tx.moveCall({
          target: `${pkg}::payloads::new_source_verification`,
          arguments: [
            tx.pure("vector<u8>", hashBytes),
            tx.pure.string(repoUrl),
            tx.pure.string(revision),
          ],
        });
        tx.moveCall({
          target: `${pkg}::registry::attest_and_keep`,
          typeArguments: [`${pkg}::payloads::SourceVerification`],
          arguments: [
            tx.object(REGISTRY_IDS[network]),
            tx.pure.address(packageId),
            payload,
          ],
        });
      }

      const result = await signAndExecute(tx, client);

      if (result.failed) {
        throw new Error(result.error ?? "Transaction failed");
      }

      setDigest(result.digest);
      await client.waitForTransaction({ digest: result.digest });
      await queryClient.invalidateQueries({ queryKey: ["attestations"] });
      await queryClient.invalidateQueries({ queryKey: ["my-attestations"] });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Unknown error");
    } finally {
      setIsPending(false);
    }
  }

  return (
    <div className="card">
      <h2>Create Attestation</h2>
      <form onSubmit={handleSubmit}>
        <div>
          <label>Package ID</label>
          <input
            type="text"
            value={packageId}
            onChange={(e) => setPackageId(e.target.value)}
            placeholder="0x..."
            required
          />
        </div>
        <div>
          <label>Payload Type</label>
          <select
            value={payloadType}
            onChange={(e) => setPayloadType(e.target.value as PayloadType)}
          >
            <option value="AuditReport">Audit Report</option>
            <option value="SourceVerification">Source Verification</option>
          </select>
        </div>

        {payloadType === "AuditReport" && (
          <>
            <div>
              <label>Report URL</label>
              <input
                type="url"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder="https://..."
                required
              />
            </div>
            <div>
              <label>Auditor</label>
              <input
                type="text"
                value={auditor}
                onChange={(e) => setAuditor(e.target.value)}
                placeholder="e.g. Acme Security"
                required
              />
            </div>
          </>
        )}

        {payloadType === "SourceVerification" && (
          <>
            <div>
              <label>Source Hash (hex)</label>
              <input
                type="text"
                value={sourceHash}
                onChange={(e) => setSourceHash(e.target.value)}
                placeholder="0xdeadbeef..."
                required
              />
            </div>
            <div>
              <label>Repository URL</label>
              <input
                type="url"
                value={repoUrl}
                onChange={(e) => setRepoUrl(e.target.value)}
                placeholder="https://github.com/..."
                required
              />
            </div>
            <div>
              <label>Revision</label>
              <input
                type="text"
                value={revision}
                onChange={(e) => setRevision(e.target.value)}
                placeholder="e.g. abc123 or v1.0.0"
                required
              />
            </div>
          </>
        )}

        <button type="submit" disabled={!address || isPending}>
          {isPending ? "Submitting..." : "Create Attestation"}
        </button>
      </form>
      {error && <p className="error">{error}</p>}
      {digest && (
        <p className="success">
          Success! Digest: <code>{digest}</code>
        </p>
      )}
    </div>
  );
}
