import { defineConfig } from "vite";

// Vanilla single-server Vite: no server.port literal, so inspect.sh must NOT
// emit a hardcoded-port warning for this shape, and the launcher's chosen PORT
// flows through via the CLI flag (npm run dev -- --port $PORT).
export default defineConfig({});
