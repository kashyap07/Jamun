import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The built app is loaded by the jamun host from jamun://app/.
export default defineConfig({
  plugins: [react()],
  css: {
    modules: {
      localsConvention: "camelCaseOnly",
    },
  },
  server: {
    port: 3124,
    strictPort: true,
  },
  build: {
    target: "safari16",
    sourcemap: true,
  },
  define: {
    __APP_VERSION__: JSON.stringify(process.env.npm_package_version),
    "process.env": {},
  },
  resolve: {
    alias: {
      util: "util",
    },
  },
});
