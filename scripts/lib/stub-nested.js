#!/usr/bin/env node
// Deep-tree stand-in for app-it's fixture suite.
//
// Spawns the real stub-server.js as a CHILD and stays alive, so the HTTP
// listener sits one generation deeper than this process. Launched by app-it
// that makes the tree: launcher-bash → node(this) → node(stub-server, listener)
// — i.e. the listener is at generation 2, mirroring real `npm run dev`
// (bash → npm → node-vite) and `pnpm dev` (bash → pnpm → node → next-server).
//
// This exists to guard the descendant-walk: a walk that stops at the first
// generation (the macOS `pgrep -P` space-joined-arg trap) cannot see this
// listener, so warm-reattach and `desktop:doctor` ownership would fail. The
// suite asserts they DON'T.
'use strict';

const { spawn } = require('child_process');
const path = require('path');

// Forward our args (e.g. --port N) straight through to the real stub.
const child = spawn('node', [path.join(__dirname, 'stub-server.js'), ...process.argv.slice(2)], {
  stdio: 'inherit',
});
child.on('error', (err) => {
  console.error(`stub-nested: failed to spawn node: ${err.message}`);
  process.exit(1);
});
child.on('exit', (code) => process.exit(code == null ? 0 : code));
