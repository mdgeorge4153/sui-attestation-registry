import { useCurrentClient, useCurrentNetwork } from "@mysten/dapp-kit-react";
import { useQuery } from "@tanstack/react-query";
import { REGISTRY_IDS } from "./dapp-kit";

interface RegistryTables {
  attestationsTableId: string;
  attestationsByTypeTableId: string;
}

/**
 * Fetch the Registry object to extract the inner Table object IDs.
 * The Table's dynamic fields live under the Table's UID, not the Registry's.
 */
export function useRegistryTables(): {
  tables: RegistryTables | undefined;
  isPending: boolean;
} {
  const client = useCurrentClient();
  const network = useCurrentNetwork();

  const { data, isPending } = useQuery({
    queryKey: ["registry-tables", network],
    queryFn: async () => {
      const result = await client.core.getObjects({
        objectIds: [REGISTRY_IDS[network]],
        include: { json: true },
      });
      const obj = result.objects[0];
      if (obj instanceof Error || !("json" in obj) || !obj.json) {
        throw new Error("Failed to read Registry object");
      }
      const json = obj.json as Record<string, { id: string }>;
      return {
        attestationsTableId: json.attestations.id,
        attestationsByTypeTableId: json.attestations_by_type.id,
      };
    },
    staleTime: Infinity, // Table IDs never change for a given Registry
  });

  return { tables: data, isPending };
}
