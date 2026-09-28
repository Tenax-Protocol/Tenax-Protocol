import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

// GitHub Pages serves the site from /<repository>/, and so does the preview of a build; the dev server serves it
// from the root.
export default defineConfig(({ command, isPreview }) => ({
  base: command === "build" || isPreview ? "/Tenax-Protocol/" : "/",
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
}));
