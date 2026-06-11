# macOS sibling: desktop-quit.sh — stop the persistent dev servers spawned by
#   the desktop launchers, plus any open wrapper windows.
#
# Windows beta · scaffolded · untested on real hardware · maintainer wanted.
#
# On Windows the primary shutdown is structural, not signal-based: the WPF host
# (wrapper-windows) owns a Job Object created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so disposing the job atomically reaps the
# whole dev-server tree (npm -> node -> vite -> esbuild workers) when the user
# picks "Quit" from the tray. This script is the DEFENSIVE FALLBACK, mirroring
# the macOS desktop-quit.sh: it sweeps any server left bound to a configured or
# recorded port (host crashed, Edge fallback was used, breakaway child), and
# closes leftover host / Edge windows.
#
# macOS uses `lsof -ti tcp:$port | kill`; the Windows equivalent is
# `Get-NetTCPConnection -LocalPort $port -State Listen` -> Stop-Process on the
# OwningProcess. Get-NetTCPConnection's OwningProcess maps cleanly to the
# listener (ADR 0005, lifecycle row 4 — a maintainer must confirm on hardware).
#
# Reads scripts/app-it.config.json (single source of truth — same file
# desktop-build.ps1 reads). Sweeps both frontend and backend ports.
#
# MAINTAINER: validate that the Job-Object teardown in the host already covers
# the normal Quit path so this script almost always reports "nothing to stop",
# and that the port sweep catches the Edge-fallback / orphan cases.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'app-it.config.json'

# --- Load apps from JSON (preferred) or a placeholder record (template) -------
# Internal record per app: @{ name; slug; port; backend_port }
$apps = @()
if (Test-Path $ConfigFile) {
    $cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
    foreach ($a in $cfg.apps) {
        $name = if ($a.name) { $a.name } else { '' }
        $slug = if ($a.slug) {
            $a.slug
        } else {
            ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        }
        $backend = $null
        if ($a.PSObject.Properties.Name -contains 'backend_port' -and $a.backend_port) {
            $backend = [string]$a.backend_port
        }
        $apps += [pscustomobject]@{
            name         = $name
            slug         = $slug
            port         = [string]$a.port
            backend_port = $backend
        }
    }
} else {
    $apps += [pscustomobject]@{
        name         = '__APP_NAME__'
        slug         = '__APP_SLUG__'
        port         = '__PORT__'
        backend_port = $null
    }
}

if ($apps.Count -eq 0) {
    Write-Error 'ERROR: no apps configured. Edit scripts\app-it.config.json.'
    exit 1
}

# Per-app runtime state mirrors the macOS layout but under %LOCALAPPDATA%:
#   %LOCALAPPDATA%\app-it\<slug>\{server.pid,server.port,backend.pid,backend.port}
$StateBase = Join-Path $env:LOCALAPPDATA 'app-it'

$script:ClosedAny = $false

# Three-stage cleanup for one port, mirroring sweep_port() in desktop-quit.sh:
#   1. Stop the recorded PID's process tree.
#   2. Sweep whoever still owns the listening port (re-parented children).
#   3. Wait up to ~1.5s, then force-kill stragglers.
function Stop-ProcessTree {
    # ConfirmImpact=Low keeps this prompt-free under the default $ConfirmPreference
    # (High), so the unattended desktop:quit path never blocks; -WhatIf still works.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([int]$ProcessId)
    if (-not $ProcessId) { return }
    # Depth-first: children before the parent, so the parent can't re-spawn.
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) { Stop-ProcessTree -ProcessId ([int]$child.ProcessId) }
    if ($PSCmdlet.ShouldProcess("PID $ProcessId", 'Stop process tree')) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-PortOwner {
    param([int]$Port)
    if (-not $Port) { return @() }
    try {
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique
    } catch {
        @()
    }
}

function Invoke-PortSweep {
    param([string]$PidFile, [string]$PortText)
    if ([string]::IsNullOrWhiteSpace($PortText)) { return }
    $port = 0
    if (-not [int]::TryParse($PortText, [ref]$port)) { return }

    $closed = $false

    if ($PidFile -and (Test-Path $PidFile)) {
        $recorded = (Get-Content -Raw $PidFile).Trim()
        $pidNum = 0
        # Only count it as "closed" if the recorded process was actually alive.
        # A stale server.pid (left by a crash or force-kill) otherwise makes the
        # final report claim "Stopped dev servers" when nothing was running.
        if ([int]::TryParse($recorded, [ref]$pidNum) -and
            (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) {
            Stop-ProcessTree -ProcessId $pidNum
            $closed = $true
        }
    }

    foreach ($owner in Get-PortOwner -Port $port) {
        Stop-ProcessTree -ProcessId ([int]$owner)
        $closed = $true
    }

    # Wait up to 1.5s, then hard-kill anything still bound.
    if (Get-PortOwner -Port $port) {
        for ($i = 0; $i -lt 3; $i++) {
            if (-not (Get-PortOwner -Port $port)) { break }
            Start-Sleep -Milliseconds 500
        }
        foreach ($owner in Get-PortOwner -Port $port) {
            Stop-Process -Id ([int]$owner) -Force -ErrorAction SilentlyContinue
            $closed = $true
        }
    }

    if ($closed) { $script:ClosedAny = $true }
}

foreach ($app in $apps) {
    $stateDir       = Join-Path $StateBase $app.slug
    $pidFile        = Join-Path $stateDir 'server.pid'
    $portFile       = Join-Path $stateDir 'server.port'
    $backendPidFile = Join-Path $stateDir 'backend.pid'
    $backendPortFile = Join-Path $stateDir 'backend.port'

    # Frontend: prefer recorded runtime port, fall back to configured.
    $port = if (Test-Path $portFile) { (Get-Content -Raw $portFile).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($port)) { $port = $app.port }
    Invoke-PortSweep -PidFile $pidFile -PortText $port

    if (-not [string]::IsNullOrWhiteSpace($app.port) -and $port -ne $app.port) {
        Invoke-PortSweep -PidFile $null -PortText $app.port
    }

    # Backend (multi-server), if configured.
    if (-not [string]::IsNullOrWhiteSpace($app.backend_port)) {
        $bport = if (Test-Path $backendPortFile) { (Get-Content -Raw $backendPortFile).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($bport)) { $bport = $app.backend_port }
        Invoke-PortSweep -PidFile $backendPidFile -PortText $bport
        if ($bport -ne $app.backend_port) {
            Invoke-PortSweep -PidFile $null -PortText $app.backend_port
        }
    }

    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile, $portFile, $backendPidFile, $backendPortFile
}

# --- Close leftover host / Edge windows --------------------------------------
# Normal Quit disposes the Job Object and takes the tree with it; this only
# catches a host that lost its job or an Edge-fallback window. Match the host
# .exe by name and the Edge fallback by its per-app user-data-dir argument.
foreach ($app in $apps) {
    $stateDir = Join-Path $StateBase $app.slug

    # WPF host windows: the published host .exe is named after the app.
    $hostName = $app.name
    foreach ($p in Get-Process -Name $hostName -ErrorAction SilentlyContinue) {
        Stop-ProcessTree -ProcessId $p.Id
        $script:ClosedAny = $true
    }

    # Edge --app windows from edge-fallback builds carry a per-app profile dir.
    $profileDir = Join-Path $stateDir 'WebView2'
    $edgeProcs = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*--user-data-dir=$profileDir*" }
    foreach ($p in $edgeProcs) {
        Stop-ProcessTree -ProcessId ([int]$p.ProcessId)
        $script:ClosedAny = $true
    }
}

if ($script:ClosedAny) {
    Write-Host 'Stopped dev servers and open windows.'
} else {
    Write-Host 'Nothing to stop - no servers were running.'
}
