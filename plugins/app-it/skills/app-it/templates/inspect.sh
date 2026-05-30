#!/bin/bash
# Phase 1 inspection helper. Emits a one-page report covering everything
# the agent needs to decide strategy before touching any files. Read-only.
#
# Designed to be invoked by the agent at the start of a /app-it session,
# before deciding worktree strategy, dev script, framework port semantics,
# multi-app structure, FSA usage, asset candidates, sibling-app collisions.
#
# Usage:
#   ./scripts/inspect.sh                  # report on current repo
#   APP_IT_PROJECT_ROOT=/path/to/main \
#       ./scripts/inspect.sh              # inspect a different path

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

cd "$ROOT"

print_section() {
    echo
    echo "=== $1 ==="
}

print_section "Repo location & worktree status"
echo "ROOT: $ROOT"
echo "id -un: $(id -un)"
if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
    GIT_DIR="$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null || true)"
    GIT_COMMON="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$GIT_DIR" ] && [ -n "$GIT_COMMON" ] && [ "$GIT_DIR" != "$GIT_COMMON" ]; then
        echo "WORKTREE: yes — common-dir is $GIT_COMMON"
        echo "  Pick a strategy: (a) bypass — write to main checkout; (b) APP_IT_PROJECT_ROOT env override; (c) bake worktree + document rebuild."
    else
        echo "Worktree: no (canonical checkout)"
    fi
    case "$ROOT" in
        */.claude/worktrees/*) echo "  (path matches .claude/worktrees pattern — likely an agent-spawned worktree)" ;;
    esac
fi

print_section "Project type signals (verify from disk, ignore CLAUDE.md)"
for f in package.json next.config.ts next.config.js next.config.mjs vite.config.ts vite.config.js vite.config.mjs tauri.conf.json electron.json electron-builder.yml electron-builder.json pyproject.toml requirements.txt Cargo.toml Gemfile manifest.json index.html; do
    [ -f "$ROOT/$f" ] && echo "  $f" || true
done
[ -d "$ROOT/src-tauri" ] && echo "  src-tauri/ (Tauri project)" || true
[ -d "$ROOT/apps" ] && echo "  apps/ (monorepo?)" || true
[ -d "$ROOT/packages" ] && echo "  packages/" || true
if [ -f "$ROOT/turbo.json" ] || [ -f "$ROOT/nx.json" ] || [ -f "$ROOT/pnpm-workspace.yaml" ]; then
    echo "  workspace config: $(ls "$ROOT"/turbo.json "$ROOT"/nx.json "$ROOT"/pnpm-workspace.yaml 2>/dev/null | tr '\n' ' ')"
fi

print_section "Dev / start script inventory"
if [ -f "$ROOT/package.json" ]; then
    /usr/bin/python3 - <<'PY'
import json, sys, re
try:
    with open("package.json") as f:
        pkg = json.load(f)
except Exception as e:
    print(f"  (could not parse package.json: {e})")
    sys.exit(0)
scripts = pkg.get("scripts", {})
matched = [(k, v) for k, v in scripts.items() if re.match(r"^(dev|start)(:|$)", k)]
if not matched:
    print("  (no dev/start scripts found)")
for k, v in matched:
    flag_warn = ""
    # Hardcoded -p / --port flag → launcher's PORT env will be ignored
    if re.search(r"(--port|\s-p)\s+\d+", v):
        flag_warn = "   ⚠ hardcoded port literal — bypass via direct binary or add dev:app-it"
    # concurrently / npm-run-all / turbo / pnpm -r → orchestrator detected
    elif re.search(r"\b(concurrently|npm-run-all|turbo run|pnpm -r)\b", v):
        flag_warn = "   ✓ multi-process orchestrator — A3.1 candidate (reuse existing)"
    print(f"  {k:<20} → {v}{flag_warn}")
print()
print(f"  package.json name:        {pkg.get('name', '(none)')}")
print(f"  package.json displayName: {pkg.get('displayName', '(none)')}")
PY
fi

print_section "Framework port literals (would override launcher's PORT env)"
if [ -f "$ROOT/vite.config.ts" ] || [ -f "$ROOT/vite.config.js" ] || [ -f "$ROOT/vite.config.mjs" ]; then
    for cfg in "$ROOT"/vite.config.{ts,js,mjs}; do
        [ -f "$cfg" ] || continue
        if grep -nE 'server:\s*\{[^}]*port:\s*[0-9]+' "$cfg" 2>/dev/null | head -3; then
            echo "  → vite.config.ts has hardcoded server.port literal."
            echo "    Vanilla single-server: pass --port via START_COMMAND ('npm run dev -- --port \$PORT')."
            echo "    Multi-server / proxy: edit vite.config.ts — see SKILL.md A3.2 carve-out."
        fi
        if grep -nE 'proxy:\s*\{[^}]*target:\s*["'"'"']http://localhost:[0-9]+' "$cfg" 2>/dev/null | head -3; then
            echo "  → vite.config.ts has hardcoded proxy target. Multi-server cohabiting (A3) likely."
        fi
    done
fi

print_section "FSA (File System Access) usage"
if command -v rg >/dev/null 2>&1; then
    GREP_CMD="rg --no-heading -n -E"
else
    GREP_CMD="grep -RnIE"
fi
echo "Stage 1: any FSA usage at all (polyfill candidate)"
$GREP_CMD "showDirectoryPicker|FileSystemDirectoryHandle|FileSystemFileHandle" \
    --include='*.{ts,tsx,js,jsx}' src/ services/ app/ 2>/dev/null | head -8 || echo "  (none found)"
echo
echo "Stage 2: real-I/O usage (polyfill cannot satisfy this — chrome-fallback or D)"
$GREP_CMD "\.createWritable\(|\.getFile\(\)|writable\.write\(" \
    --include='*.{ts,tsx,js,jsx}' src/ services/ app/ 2>/dev/null | head -8 || echo "  (none found)"

print_section "Sibling appified apps & their preferred ports (collision check)"
PORTS_FOUND=""
for install_dir in "$HOME/Applications/App It" "$HOME/Desktop/MyApps"; do
    [ -d "$install_dir" ] || continue
    for app in "$install_dir"/*.app; do
        [ -d "$app" ] || continue
        name="$(basename "$app" .app)"
        run_script="$app/Contents/MacOS/run"
        if [ -f "$run_script" ]; then
            port="$(grep -E "^PREFERRED(_FE)?_PORT=" "$run_script" 2>/dev/null | head -1 | cut -d= -f2 || true)"
            if [ -n "$port" ]; then
                echo "  $name → :$port ($install_dir)"
                PORTS_FOUND="$PORTS_FOUND $port"
            fi
        fi
    done
done
if [ -z "$PORTS_FOUND" ]; then
    echo "  (no app-it launchers found under ~/Applications/App It or legacy ~/Desktop/MyApps)"
fi

print_section "Currently bound ports (3000–5200 range)"
for p in 3000 3001 3002 3003 3004 3005 5173 5174 5175 8000 8080; do
    holder="$(lsof -i tcp:"$p" -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1 {printf "%s/%s ", $1, $2}' || true)"
    [ -n "$holder" ] && echo "  :$p — $holder" || true
done

print_section "Toolchain availability"
for cmd in swiftc node npm pnpm yarn bun deno python3 cargo; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  $cmd → $(command -v "$cmd")"
    fi
done

print_section "Runtime data paths the launcher will need (process.cwd, env-keyed paths)"
$GREP_CMD "process\.cwd\(\)|process\.env\.[A-Z_]+|sqlite:\/\/\/|file:\.\/[^ \"']+" \
    --include='*.{ts,tsx,js,jsx,py}' src/ lib/ services/ app/ 2>/dev/null | head -10 || echo "  (none found)"

print_section "Gitignored runtime artifacts (data files, caches the launcher needs)"
if [ -f "$ROOT/.gitignore" ]; then
    grep -E "^(data/|\.env|.*\.db|.*\.sqlite|cache/|\.next/|build/|dist/)" "$ROOT/.gitignore" 2>/dev/null | head -10 || echo "  (no obvious data/env entries in .gitignore)"
fi

print_section "Asset candidates (potential icon sources)"
if command -v find >/dev/null 2>&1; then
    find "$ROOT" -maxdepth 4 \
        \( -path '*/node_modules' -prune -o -path '*/.git' -prune -o -path '*/desktop' -prune \) -o \
        \( -iname 'app-icon*' -o -iname 'app_icon*' -o -iname 'appicon*' \
           -o -iname 'icon.png' -o -iname 'icon.svg' -o -iname 'icon@*.png' \
           -o -iname 'logo*.png' -o -iname 'logo*.svg' \
           -o -iname 'apple-touch-icon*' -o -iname 'android-chrome-*' \
           -o -iname 'favicon-512*' -o -iname 'manifest.json' \
        \) -size +1k -type f -print 2>/dev/null | head -15
fi

print_section "Recent git commit subjects (project-name vocabulary)"
if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
    git -C "$ROOT" log --pretty=%s -10 2>/dev/null | head -10 || echo "  (no git history)"
fi

echo
echo "=== End of inspection ==="
echo "Next: pick worktree strategy (if applicable), strategy (A1/A2/A3/A4/B/D),"
echo "      bundle ID prefix (NOT com.\$(id -un).*), and dev script per app."
