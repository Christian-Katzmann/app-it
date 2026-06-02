// Stand-in backend. The real launcher exports API_PORT (and PORT) to this
// process; an Express entrypoint would read process.env.API_PORT first. The
// suite swaps this for scripts/lib/stub-server.js (which resolves API_PORT) so
// the multiserver launch path is exercised without an npm install.
const http = require("http");
const port = process.env.API_PORT || process.env.PORT || 3001;
http.createServer((_req, res) => res.end("backend ok")).listen(Number(port), "127.0.0.1");
