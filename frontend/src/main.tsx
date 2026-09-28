import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { App } from "./App.js";
import "@fontsource-variable/archivo/wdth.css";
import "@fontsource-variable/inter";
import "./styles.css";
import { wagmiConfig } from "./wagmi.js";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, retry: 2 } },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <App />
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
);
