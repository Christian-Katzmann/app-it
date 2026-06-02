import { defineConfig } from "vite";

// The footgun this fixture guards: a hardcoded port literal makes the framework
// ignore the launcher's chosen PORT. Both inspect.sh signals must keep firing —
// the "dev" script's --port literal AND the server.port literal below. Kept on
// one line so inspect.sh's line-based server.port regex matches.
export default defineConfig({
  server: { port: 5173 },
});
