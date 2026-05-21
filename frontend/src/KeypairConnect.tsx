import { useState } from "react";
import { useKeypair } from "./KeypairContext";

export function KeypairConnect() {
  const { address, connect, disconnect } = useKeypair();
  const [input, setInput] = useState("");
  const [error, setError] = useState<string | null>(null);

  function handleConnect(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    try {
      connect(input.trim());
      setInput("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Invalid key");
    }
  }

  if (address) {
    return (
      <div className="connect-row">
        <span className="address">
          {address.slice(0, 8)}...{address.slice(-6)}
        </span>
        <button className="disconnect-btn" onClick={disconnect}>
          Disconnect
        </button>
      </div>
    );
  }

  return (
    <div className="keypair-connect">
      <form onSubmit={handleConnect} className="connect-form">
        <input
          type="password"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Paste base64 secret key from sui.keystore"
        />
        <button type="submit">Connect</button>
      </form>
      {error && <p className="error">{error}</p>}
      <p className="muted" style={{ fontSize: "0.8rem", marginTop: "0.25rem" }}>
        Testnet only. Find your key in ~/.sui/sui_config/sui.keystore
      </p>
    </div>
  );
}
