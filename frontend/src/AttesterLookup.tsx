import { useState } from "react";
import { useCurrentClient, useCurrentNetwork } from "@mysten/dapp-kit-react";
import { useQuery } from "@tanstack/react-query";
import { ORIGINAL_PACKAGE_IDS } from "./dapp-kit";
import { AttestationCard } from "./AttestationCard";
import type { AttestationData } from "./AttestationCard";

/** Extract the short payload type name from the full on-chain type. */
function payloadType(fullType: string): string {
  const match = fullType.match(/<.*::(\w+)>$/);
  return match ? match[1] : "";
}

export function AttesterLookup() {
  const client = useCurrentClient();
  const network = useCurrentNetwork();
  const [attesterInput, setAttesterInput] = useState("");
  const [typeFilter, setTypeFilter] = useState("");
  const [searchAttester, setSearchAttester] = useState("");
  const [searchType, setSearchType] = useState("");

  const originalPkg = ORIGINAL_PACKAGE_IDS[network];

  const { data: attestations, isPending } = useQuery({
    queryKey: ["attester-attestations", searchAttester, searchType, network],
    queryFn: async () => {
      // Attestation<T> is generic — query all Attestation types owned by this address.
      // listOwnedObjects with a partial type match works for the base struct.
      const result = await client.core.listOwnedObjects({
        owner: searchAttester,
        type: `${originalPkg}::registry::Attestation`,
        include: { json: true },
        limit: 50,
      });
      let items: AttestationData[] = result.objects
        .filter((o) => o.json)
        .map((o) => ({
          id: o.objectId,
          type: o.type ?? "",
          fields: o.json as unknown as AttestationData["fields"],
        }));
      if (searchType) {
        items = items.filter((a) => payloadType(a.type) === searchType);
      }
      return items;
    },
    enabled: !!searchAttester,
    retry: false,
  });

  function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    setSearchAttester(attesterInput.trim());
    setSearchType(typeFilter);
  }

  return (
    <div className="card">
      <h2>Lookup by Attester</h2>
      <form onSubmit={handleSearch}>
        <div>
          <label>Attester Address</label>
          <input
            type="text"
            value={attesterInput}
            onChange={(e) => setAttesterInput(e.target.value)}
            placeholder="0x..."
            required
          />
        </div>
        <div>
          <label>Payload Type (optional)</label>
          <select
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
          >
            <option value="">All types</option>
            <option value="AuditReport">Audit Report</option>
            <option value="SourceVerification">Source Verification</option>
          </select>
        </div>
        <button type="submit">Search</button>
      </form>

      {searchAttester && isPending && <p>Loading...</p>}

      {searchAttester &&
        !isPending &&
        (!attestations || attestations.length === 0) && (
          <p className="muted">
            No attestations found for this attester
            {searchType ? ` with type "${searchType}"` : ""}.
          </p>
        )}

      {attestations && attestations.length > 0 && (
        <div className="results">
          <h3>{attestations.length} attestation(s) found</h3>
          {attestations.map((a) => (
            <AttestationCard key={a.id} attestation={a} />
          ))}
        </div>
      )}
    </div>
  );
}
