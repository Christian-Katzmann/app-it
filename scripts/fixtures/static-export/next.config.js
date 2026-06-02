// output: 'export' → Next emits a fully static site into out/. inspect-static.sh
// must detect this as "Next.js (static export)" with static_dir "out". The
// suite ships a prebuilt out/ so app-it-static can serve it with the real
// static-server.py — no `next build` (and no node_modules) needed.
module.exports = { output: "export" };
