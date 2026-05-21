import { createDAppKit } from "@mysten/dapp-kit-react";
import { SuiGrpcClient } from "@mysten/sui/grpc";

const GRPC_URLS: Record<string, string> = {
  testnet: "https://fullnode.testnet.sui.io:443",
};

// Latest (upgraded) package ID — used for function calls
export const PACKAGE_IDS: Record<string, string> = {
  testnet:
    "0xedf62badb49975f9938a6b0595617e9b7611e19f16e7579da05c85d2df1cd780",
};

// Original package ID — used for type queries (struct types are anchored here)
export const ORIGINAL_PACKAGE_IDS: Record<string, string> = {
  testnet:
    "0xedf62badb49975f9938a6b0595617e9b7611e19f16e7579da05c85d2df1cd780",
};

// Shared registry object
export const REGISTRY_IDS: Record<string, string> = {
  testnet:
    "0x4c6efc9e52f18b99a3d988c5df36b9d5d6fbff0031d658795cd9bc1a37089975",
};

// Table object IDs within the Registry (children of the Registry's fields)
export const ATTESTATIONS_TABLE_IDS: Record<string, string> = {
  testnet:
    "0x68adde659b1db73dab9731a892a0dccd006fa94daee07c6987d703d7f30c8170",
};

export const ATTESTATIONS_BY_TYPE_TABLE_IDS: Record<string, string> = {
  testnet:
    "0x301c9e3d258b572d5ccdee69743334de332181deccc958f4c9c2d7fdaab76365",
};

export const dAppKit = createDAppKit({
  networks: ["testnet"],
  defaultNetwork: "testnet",
  createClient: (network) =>
    new SuiGrpcClient({ network, baseUrl: GRPC_URLS[network] }),
});

declare module "@mysten/dapp-kit-react" {
  interface Register {
    dAppKit: typeof dAppKit;
  }
}
