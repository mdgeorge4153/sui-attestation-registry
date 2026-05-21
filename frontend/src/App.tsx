import { useState } from "react";
import { CreateAttestation } from "./CreateAttestation";
import { LookupAttestations } from "./LookupAttestations";
import { AttesterLookup } from "./AttesterLookup";
import { MyAttestations } from "./MyAttestations";
import { KeypairConnect } from "./KeypairConnect";
import { useKeypair } from "./KeypairContext";
import "./App.css";

type Tab = "lookup" | "attester" | "create" | "mine";

function App() {
  const { address } = useKeypair();
  const [tab, setTab] = useState<Tab>("lookup");

  return (
    <div className="container">
      <header>
        <h1>Sui Attestation Registry</h1>
        <p className="subtitle">
          On-chain attestations for Sui packages — audit reports, security
          reviews, and more.
        </p>
        <KeypairConnect />
      </header>

      <nav className="tabs">
        <button
          className={tab === "lookup" ? "active" : ""}
          onClick={() => setTab("lookup")}
        >
          By Package
        </button>
        <button
          className={tab === "attester" ? "active" : ""}
          onClick={() => setTab("attester")}
        >
          By Attester
        </button>
        <button
          className={tab === "create" ? "active" : ""}
          onClick={() => setTab("create")}
          disabled={!address}
          title={!address ? "Connect keypair first" : undefined}
        >
          Create
        </button>
        <button
          className={tab === "mine" ? "active" : ""}
          onClick={() => setTab("mine")}
          disabled={!address}
          title={!address ? "Connect keypair first" : undefined}
        >
          My Attestations
        </button>
      </nav>

      <main>
        {tab === "lookup" && <LookupAttestations />}
        {tab === "attester" && <AttesterLookup />}
        {tab === "create" && <CreateAttestation />}
        {tab === "mine" && <MyAttestations />}
      </main>
    </div>
  );
}

export default App;
