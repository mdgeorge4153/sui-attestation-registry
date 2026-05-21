import { useState, useMemo } from "react";
import { useCurrentClient, useCurrentNetwork } from "@mysten/dapp-kit-react";
import { useQuery } from "@tanstack/react-query";
import { bcs } from "@mysten/sui/bcs";
import { ATTESTATIONS_TABLE_IDS } from "./dapp-kit";
import { AttestationCard } from "./AttestationCard";
import type { AttestationData } from "./AttestationCard";

/** Extract the short payload type name from the full on-chain type. */
function payloadType(fullType: string): string {
  const match = fullType.match(/<.*::(\w+)>$/);
  return match ? match[1] : "";
}

export function LookupAttestations() {
  const client = useCurrentClient();
  const network = useCurrentNetwork();
  const [packageId, setPackageId] = useState("");
  const [searchId, setSearchId] = useState("");

  // Filters
  const [typeFilter, setTypeFilter] = useState("");
  const [trustedAttesters, setTrustedAttesters] = useState("");

  const { data: attestationIds, isPending: idsLoading, error: idsError } = useQuery({
    queryKey: ["attestations", "index", searchId, network],
    queryFn: async () => {
      const addressBytes = bcs.Address.serialize(searchId).toBytes();
      const result = await client.core.getDynamicField({
        parentId: ATTESTATIONS_TABLE_IDS[network],
        name: { type: "address", bcs: addressBytes },
      });
      const valueBcs = result.dynamicField.value.bcs;
      const parsed = bcs.vector(bcs.Address).parse(valueBcs);
      return parsed as string[];
    },
    enabled: !!searchId,
    retry: false,
  });

  const { data: attestations, isPending: objectsLoading } = useQuery({
    queryKey: ["attestations", "objects", attestationIds],
    queryFn: async () => {
      if (!attestationIds || attestationIds.length === 0) return [];
      const result = await client.core.getObjects({
        objectIds: attestationIds,
        include: { json: true },
      });
      return result.objects
        .filter(
          (o): o is Exclude<typeof o, Error> =>
            !(o instanceof Error) && "json" in o && !!o.json,
        )
        .map((o) => ({
          id: o.objectId,
          type: o.type ?? "",
          fields: o.json as unknown as AttestationData["fields"],
        }));
    },
    enabled: !!attestationIds && attestationIds.length > 0,
  });

  const filtered = useMemo(() => {
    if (!attestations) return [];
    const attesterSet = trustedAttesters
      ? new Set(
          trustedAttesters
            .split(/[,\n]/)
            .map((s) => s.trim().toLowerCase())
            .filter(Boolean),
        )
      : null;

    return attestations.filter((a) => {
      if (typeFilter && payloadType(a.type) !== typeFilter) return false;
      if (attesterSet && !attesterSet.has(a.fields.attester.toLowerCase()))
        return false;
      return true;
    });
  }, [attestations, typeFilter, trustedAttesters]);

  function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    setSearchId(packageId);
  }

  const isPending = searchId && (idsLoading || objectsLoading);
  const hasResults = searchId && !isPending && !idsError && attestations;

  return (
    <div className="card">
      <h2>Lookup by Package</h2>
      <form onSubmit={handleSearch}>
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
        <button type="submit">Search</button>
      </form>

      {hasResults && attestations.length > 0 && (
        <div className="filters">
          <div className="filter-row">
            <div>
              <label>Filter by type</label>
              <select
                value={typeFilter}
                onChange={(e) => setTypeFilter(e.target.value)}
              >
                <option value="">All types</option>
                <option value="AuditReport">Audit Report</option>
                <option value="SourceVerification">Source Verification</option>
              </select>
            </div>
            <div>
              <label>Trusted attesters only (comma-separated)</label>
              <input
                type="text"
                value={trustedAttesters}
                onChange={(e) => setTrustedAttesters(e.target.value)}
                placeholder="0xabc..., 0xdef..."
              />
            </div>
          </div>
        </div>
      )}

      {isPending && <p>Loading...</p>}

      {searchId && !isPending && idsError && (
        <p className="muted">No attestations found for this package.</p>
      )}

      {hasResults && attestations.length === 0 && (
        <p className="muted">No attestations found for this package.</p>
      )}

      {hasResults && attestations.length > 0 && (
        <div className="results">
          <h3>
            {filtered.length} of {attestations.length} attestation(s)
            {typeFilter || trustedAttesters ? " (filtered)" : ""}
          </h3>
          {filtered.length === 0 && (
            <p className="muted">No attestations match the current filters.</p>
          )}
          {filtered.map((a) => (
            <AttestationCard key={a.id} attestation={a} />
          ))}
        </div>
      )}
    </div>
  );
}
