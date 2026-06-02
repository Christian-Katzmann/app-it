import { defineConfig } from "vite";

// Cohabiting frontend + backend: the proxy target points at a separate backend
// port, which is inspect.sh's "multi-server (A3) likely" signal. Kept on one
// line so inspect.sh's line-based proxy regex matches.
export default defineConfig({
  server: { proxy: { "/api": { target: "http://localhost:3001", changeOrigin: true } } },
});
