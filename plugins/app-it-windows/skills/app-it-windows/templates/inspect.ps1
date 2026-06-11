# macOS sibling: inspect.sh — Phase 1 read-only inspection helper. Emits a
#   one-page report covering everything the agent needs to decide strategy
#   before touching any files.
#
# Windows beta · scaffolded · untested on real hardware · maintainer wanted.
#
# Windows-shaped report: same skeleton as inspect.sh (worktree status, project
# type, dev-script inventory, port literals, sibling apps, bound ports,
# toolchain), plus three Windows-specific probes the macOS version has no need
# for: WebView2 Evergreen runtime presence, .NET SDK presence, and port
# collisions against currently-listening sockets.
#
# Usage:
#   pwsh .\scripts\inspect.ps1
#   $env:APP_IT_PROJECT_ROOT='C:\path\to\main'; pwsh .\scripts\inspect.ps1

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = if ($env:APP_IT_PROJECT_ROOT) { $env:APP_IT_PROJECT_ROOT } else { (Resolve-Path (Join-Path $ScriptDir '..')).Path }
Set-Location $Root

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" }

Write-Section 'Repo location & worktree status'
Write-Host "ROOT: $Root"
Write-Host "user: $env:USERNAME"
if ((Test-Path (Join-Path $Root '.git'))) {
    $gitDir    = (git -C $Root rev-parse --git-dir 2>$null)
    $gitCommon = (git -C $Root rev-parse --git-common-dir 2>$null)
    if ($gitDir -and $gitCommon -and ($gitDir -ne $gitCommon)) {
        Write-Host "WORKTREE: yes - common-dir is $gitCommon"
        Write-Host '  Pick a strategy: (a) bypass - write to main checkout; (b) APP_IT_PROJECT_ROOT env override; (c) bake worktree + document rebuild.'
    } else {
        Write-Host 'Worktree: no (canonical checkout)'
    }
}

Write-Section 'Project type signals (verify from disk, ignore CLAUDE.md)'
$signals = @(
    'package.json','next.config.ts','next.config.js','next.config.mjs',
    'vite.config.ts','vite.config.js','vite.config.mjs','tauri.conf.json',
    'electron.json','electron-builder.yml','electron-builder.json',
    'pyproject.toml','requirements.txt','Cargo.toml','Gemfile','manifest.json','index.html'
)
foreach ($f in $signals) { if (Test-Path (Join-Path $Root $f)) { Write-Host "  $f" } }
if (Test-Path (Join-Path $Root 'src-tauri')) { Write-Host '  src-tauri/ (Tauri project)' }
if (Test-Path (Join-Path $Root 'apps'))      { Write-Host '  apps/ (monorepo?)' }
if (Test-Path (Join-Path $Root 'packages'))  { Write-Host '  packages/' }
foreach ($w in 'turbo.json','nx.json','pnpm-workspace.yaml') {
    if (Test-Path (Join-Path $Root $w)) { Write-Host "  workspace config: $w" }
}

Write-Section 'Dev / start script inventory'
$pkgPath = Join-Path $Root 'package.json'
if (Test-Path $pkgPath) {
    try {
        $pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
        $scripts = $pkg.scripts
        $matched = @()
        if ($scripts) {
            foreach ($prop in $scripts.PSObject.Properties) {
                if ($prop.Name -match '^(dev|start)(:|$)') { $matched += $prop }
            }
        }
        if ($matched.Count -eq 0) { Write-Host '  (no dev/start scripts found)' }
        foreach ($m in $matched) {
            $warn = ''
            if ($m.Value -match '(--port|\s-p)\s+\d+') {
                $warn = '   ! hardcoded port literal - bypass via direct binary or add dev:app-it'
            } elseif ($m.Value -match '\b(concurrently|npm-run-all|turbo run|pnpm -r)\b') {
                $warn = '   + multi-process orchestrator - multi-server candidate'
            }
            Write-Host ("  {0,-20} -> {1}{2}" -f $m.Name, $m.Value, $warn)
        }
        Write-Host ''
        Write-Host "  package.json name:        $($pkg.name)"
        if ($pkg.PSObject.Properties.Name -contains 'displayName') {
            Write-Host "  package.json displayName: $($pkg.displayName)"
        }
    } catch {
        Write-Host "  (could not parse package.json: $_)"
    }
}

Write-Section 'Framework port literals (would override launcher PORT env)'
foreach ($cfg in 'vite.config.ts','vite.config.js','vite.config.mjs') {
    $p = Join-Path $Root $cfg
    if (Test-Path $p) {
        $txt = Get-Content -Raw $p
        if ($txt -match 'server:\s*\{[^}]*port:\s*[0-9]+') {
            Write-Host "  -> $cfg has a hardcoded server.port literal."
            Write-Host "     Single-server: pass --port via start_command ('npm run dev -- --port `$env:PORT')."
        }
        if ($txt -match 'proxy:\s*\{[^}]*target:\s*["''`]http://localhost:[0-9]+') {
            Write-Host "  -> $cfg has a hardcoded proxy target. Multi-server cohabiting likely."
        }
    }
}

Write-Section 'FSA (File System Access) usage'
$searchDirs = @('src','services','app','lib') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }
function Search-Code {
    param([string]$Pattern, [string[]]$Dirs)
    # -not covers $null (no dir matched Test-Path) and @() alike. $Dirs.Count
    # would throw under StrictMode when the pipeline that built it yielded $null.
    if (-not $Dirs) { return @() }
    Get-ChildItem -Path $Dirs -Recurse -Include *.ts,*.tsx,*.js,*.jsx -ErrorAction SilentlyContinue |
        Select-String -Pattern $Pattern -ErrorAction SilentlyContinue
}
Write-Host 'Stage 1: any FSA usage at all (polyfill candidate)'
$s1 = Search-Code -Pattern 'showDirectoryPicker|FileSystemDirectoryHandle|FileSystemFileHandle' -Dirs $searchDirs | Select-Object -First 8
if ($s1) { $s1 | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" } } else { Write-Host '  (none found)' }
Write-Host ''
Write-Host 'Stage 2: real-I/O usage (polyfill cannot satisfy this - edge fallback or rework)'
$s2 = Search-Code -Pattern '\.createWritable\(|\.getFile\(\)|writable\.write\(' -Dirs $searchDirs | Select-Object -First 8
if ($s2) { $s2 | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" } } else { Write-Host '  (none found)' }

Write-Section 'Sibling appified apps & their preferred ports (collision check)'
# macOS scans ~/Applications/App It; the Windows analog is the per-app runtime
# state under %LOCALAPPDATA%\app-it\<slug>\server.port plus the Start Menu folder.
$found = $false
$stateBase = Join-Path $env:LOCALAPPDATA 'app-it'
if (Test-Path $stateBase) {
    foreach ($d in Get-ChildItem -Directory $stateBase -ErrorAction SilentlyContinue) {
        $pf = Join-Path $d.FullName 'server.port'
        if (Test-Path $pf) {
            $port = (Get-Content -Raw $pf).Trim()
            Write-Host "  $($d.Name) -> :$port (last runtime port)"
            $found = $true
        }
    }
}
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\app-it'
if (Test-Path $startMenu) {
    foreach ($lnk in Get-ChildItem -Path $startMenu -Filter *.lnk -ErrorAction SilentlyContinue) {
        Write-Host "  shortcut: $($lnk.Name)"
        $found = $true
    }
}
if (-not $found) { Write-Host '  (no app-it launchers found under %LOCALAPPDATA%\app-it or the Start Menu app-it folder)' }

Write-Section 'Currently bound ports (3000-5200 range) + collisions'
foreach ($p in 3000,3001,3002,3003,3004,3005,5173,5174,5175,8000,8080) {
    $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        $owners = $conns | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
            $proc = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($proc) { "$($proc.ProcessName)/$_" } else { "pid $_" }
        }
        Write-Host "  :$p - $($owners -join ' ')  [COLLISION]"
    }
}

Write-Section 'Toolchain availability'
foreach ($cmd in 'dotnet','node','npm','pnpm','yarn','bun','deno','python','git') {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($c) { Write-Host "  $cmd -> $($c.Source)" }
}

Write-Section '.NET SDK (needed to build the WebView2 host via dotnet publish)'
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $sdks = & dotnet --list-sdks 2>$null
    if ($sdks) {
        $sdks | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host '  dotnet present but no SDKs listed (runtime-only install?) - dotnet publish will fail.'
    }
} else {
    Write-Host '  dotnet not found. Install the .NET 8 SDK, or the build falls back to the Edge --app launcher.'
}

Write-Section 'WebView2 Evergreen runtime'
# Per ADR 0005: WebView2 ships with Win11 and recent Win10 but is not
# guaranteed. The runtime registers a version under these keys (per-machine,
# 32/64-bit views, then per-user). Empty pv => not installed.
$wv2Keys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
$wv2Version = $null
foreach ($k in $wv2Keys) {
    $item = Get-ItemProperty -Path $k -Name pv -ErrorAction SilentlyContinue
    if ($item -and $item.pv -and $item.pv -ne '0.0.0.0') { $wv2Version = $item.pv; break }
}
if ($wv2Version) {
    Write-Host "  WebView2 runtime present: $wv2Version"
} else {
    Write-Host '  WebView2 runtime NOT detected. The WPF host needs it; without it, use the Edge --app fallback'
    Write-Host '  or install the Evergreen Bootstrapper from https://developer.microsoft.com/microsoft-edge/webview2/'
}

Write-Section 'Recent git commit subjects (project-name vocabulary)'
if (Test-Path (Join-Path $Root '.git')) {
    $log = git -C $Root log --pretty=%s -10 2>$null
    if ($log) { $log | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (no git history)' }
}

Write-Host ''
Write-Host '=== End of inspection ==='
Write-Host 'Next: pick worktree strategy (if applicable), launcher mode (WebView2 host vs Edge fallback),'
Write-Host '      bundle_id key, and dev script per app.'
