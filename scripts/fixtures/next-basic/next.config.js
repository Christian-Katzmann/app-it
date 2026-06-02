// Next.js (non-export) — needs a Node runtime. `next dev` reads the PORT env
// directly (no --port needed), and the "dev" script carries no -p literal, so
// inspect.sh must detect Next here and emit no hardcoded-port warning.
module.exports = {};
