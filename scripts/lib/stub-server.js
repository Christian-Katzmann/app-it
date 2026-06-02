#!/usr/bin/env node
// Tiny $PORT-honoring stand-in dev server for app-it's fixture suite.
//
// app-it's launcher is framework-agnostic: it just runs whatever START_COMMAND
// honors the PORT it chose. This stand-in lets the suite exercise the REAL
// launcher machinery (port scan/fallback, daemonized spawn, two-stage readiness
// probe, descendant-walk reattach, ownership, teardown) WITHOUT installing a
// framework — so fixtures stay tiny and CI stays fast and deterministic.
// Proving the real frameworks still launch is the job of the `vite-real` lane
// and the manual release smoke, not this stub.
//
// Port resolution mirrors the command shapes app-it generates:
//   1. `--port N`            Vite-style frontend  (`npm run dev -- --port $PORT`)
//   2. process.env.API_PORT  multiserver backend  (the entrypoint reads API_PORT first)
//   3. process.env.PORT      Express / Next-style  (reads the PORT env)
'use strict';

const http = require('http');

function resolvePort() {
  const i = process.argv.indexOf('--port');
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  return process.env.API_PORT || process.env.PORT;
}

const port = Number(resolvePort());
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  console.error('stub-server: invalid/missing port (pass --port N or set PORT / API_PORT)');
  process.exit(1);
}

const label = process.env.STUB_LABEL || 'app-it fixture stub';
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><meta charset="utf-8"><title>${label}</title>` +
          `<h1>${label}</h1><p>serving on port ${port}</p>`);
});

// A clean one-line message in the launcher log beats an unhandled 'error' stack.
server.on('error', (err) => {
  console.error(`stub-server: ${err.code || err.message} binding 127.0.0.1:${port}`);
  process.exit(1);
});

// Bind 127.0.0.1 only — a local stand-in, never a host.
server.listen(port, '127.0.0.1', () => {
  console.log(`stub-server: ${label} listening on http://127.0.0.1:${port}`);
});
