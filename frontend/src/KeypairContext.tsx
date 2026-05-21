import { createContext, useContext, useState, useCallback } from "react";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import type { Keypair } from "@mysten/sui/cryptography";

interface KeypairState {
  keypair: Keypair | null;
  address: string | null;
  connect: (secretKey: string) => void;
  disconnect: () => void;
  signAndExecute: (
    tx: Transaction,
    client: SuiGrpcClient,
  ) => Promise<{ digest: string; failed: boolean; error?: string }>;
}

const KeypairContext = createContext<KeypairState>({
  keypair: null,
  address: null,
  connect: () => {},
  disconnect: () => {},
  signAndExecute: () => Promise.reject("No keypair"),
});

export function useKeypair() {
  return useContext(KeypairContext);
}

export function KeypairProvider({ children }: { children: React.ReactNode }) {
  const [keypair, setKeypair] = useState<Keypair | null>(null);
  const [address, setAddress] = useState<string | null>(null);

  const connect = useCallback((secretKey: string) => {
    // The keystore format is base64-encoded: 1 byte scheme flag + 32 bytes secret key
    const bytes = Uint8Array.from(atob(secretKey), (c) => c.charCodeAt(0));
    // First byte is the scheme flag (0 = Ed25519), rest is the secret key
    const rawKey = bytes.slice(1);
    const kp = Ed25519Keypair.fromSecretKey(rawKey);
    setKeypair(kp);
    setAddress(kp.toSuiAddress());
  }, []);

  const disconnect = useCallback(() => {
    setKeypair(null);
    setAddress(null);
  }, []);

  const signAndExecute = useCallback(
    async (tx: Transaction, client: SuiGrpcClient) => {
      if (!keypair) throw new Error("No keypair connected");
      const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        include: { effects: true },
      });
      if (result.$kind === "FailedTransaction") {
        return {
          digest: "",
          failed: true,
          error:
            result.FailedTransaction.status.error?.message ??
            "Transaction failed",
        };
      }
      return { digest: result.Transaction.digest, failed: false };
    },
    [keypair],
  );

  return (
    <KeypairContext.Provider
      value={{ keypair, address, connect, disconnect, signAndExecute }}
    >
      {children}
    </KeypairContext.Provider>
  );
}
