import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { DAppKitProvider } from "@mysten/dapp-kit-react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { dAppKit } from "./dapp-kit";
import { KeypairProvider } from "./KeypairContext";
import App from "./App";
import "./index.css";

const queryClient = new QueryClient();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <DAppKitProvider dAppKit={dAppKit}>
        <KeypairProvider>
          <App />
        </KeypairProvider>
      </DAppKitProvider>
    </QueryClientProvider>
  </StrictMode>,
);
