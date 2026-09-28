import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

// Relative asset paths: with hash routing every page is index.html, so the same build works at the root of
// tenax.brmz.com.br and under the repository's github.io path.
export default defineConfig({
  base: "./",
  plugins: [react()],
  // viem and the wallet connectors make up most of the bundle, about 200 kB compressed.
  build: { chunkSizeWarningLimit: 1000 },
  resolve: {
    alias: {
      "@abi": here("../offchain/src/abi/index.ts"),
      "@deployments": here("../deployments"),
    },
  },
  server: { fs: { allow: [here("..")] } },
});
