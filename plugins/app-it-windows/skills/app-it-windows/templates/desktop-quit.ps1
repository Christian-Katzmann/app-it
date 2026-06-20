# macOS sibling: desktop-quit.sh - stop the persistent dev servers spawned by
#   the desktop launchers, plus any open wrapper windows.
#
# Windows beta - scaffolded - untested on real hardware - maintainer wanted.
#
# On Windows the primary shutdown is structural, not signal-based: the WPF host
# (wrapper-windows) owns a Job Object created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so disposing the job atomically reaps the
# whole dev-server tree (npm -> node -> vite -> esbuild workers) when the user
# picks "Quit" from the tray. This script is the DEFENSIVE FALLBACK for whatever
# slips past that (host crashed, Edge fallback was used, a child broke away).
#
# OWNERSHIP DISCIPLINE (mirrors stop_owned_runtime in desktop-quit.sh). The old
# beta swept whatever process owned the recorded port - that could kill a
# process this launcher never started (recycled PID, or a different app that
# grabbed the port after ours exited). This script now refuses to stop anything
# it cannot PROVE it owns:
#
#   * Identity token. The launcher records the dev server's creation time as an
#     invariant UTC FILETIME in server.identity (the Windows reading of macOS
#     `ps -o lstart=`). A recorded PID is stopped only when that token still
#     matches the live PID - so a recycled/foreign PID, which has a different
#     creation time, is left alone.
#   * Legacy proof. State written before identity tokens existed has no
#     server.identity. There we fall back to the macOS rule: stop the recorded
#     PID tree only when that tree genuinely owns the listener on the recorded
#     (or preferred) port.
#
# A live process we cannot prove is ours is never stopped; its state files are
# simply treated as stale and removed. Open host/Edge windows are matched by
# app identity (the host .exe is named after the app; the Edge fallback by its
# per-app user-data-dir), not by port, so they carry no "kill a stranger" risk.
#
# Reads scripts/app-it.config.json (single source of truth - the same file
# desktop-build.ps1 reads). Handles both frontend and backend state.
#
# MAINTAINER: validate on real hardware that the Job-Object teardown in the host
# already covers the normal Quit path (so this script almost always reports
# "nothing to stop"), and that the ownership proof correctly stops an orphaned
# dev-server tree while leaving an unrelated process on the same port running.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================================
# Ownership helpers. Defined at script scope so the Pester suite can dot-source
# this file and exercise the decision logic without running the cleanup (the
# entrypoint at the bottom is guarded against dot-sourcing).
# =============================================================================

# The process creation time as an invariant token (UTC FILETIME), the Windows
# analog of macOS `ps -o lstart=`. Empty string when the PID is gone or its
# start time is unreadable (e.g. access denied) - callers treat empty as "cannot
# prove", never as a match.
function Get-ProcessIdentity {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return '' }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        return $proc.StartTime.ToFileTimeUtc().ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return ''
    }
}

# True only when the recorded identity token exists AND equals the live PID's
# current token. A recycled or foreign PID yields a different (or empty) token,
# so this returns false and the caller must NOT stop that PID.
function Test-ProcessIdentityMatch {
    param([int]$ProcessId, [string]$IdentityFile)
    if (-not $IdentityFile -or -not (Test-Path $IdentityFile)) { return $false }
    $recorded = Get-Content -Raw -Path $IdentityFile -ErrorAction SilentlyContinue
    if ($null -eq $recorded) { return $false }
    $recorded = $recorded.Trim()
    if (-not $recorded) { return $false }
    $current = Get-ProcessIdentity -ProcessId $ProcessId
    return (($current -ne '') -and ($recorded -eq $current))
}

# Every PID in the recorded process's subtree (root included), from a single
# Win32_Process snapshot. Mirrors descendant_tree() in desktop-quit.sh (the
# `pgrep -P` walk). Windows-specific guard: a genuine child cannot predate the
# parent whose PID it claims, which stops parent-PID recycling from pulling an
# unrelated process into the tree (a hazard macOS's live `pgrep -P` avoids).
function Get-DescendantTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return @() }

    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    if (-not $all) { return @($ProcessId) }

    $byId = @{}
    $childrenByParent = @{}
    foreach ($proc in $all) {
        $byId[[int]$proc.ProcessId] = $proc
        $parentKey = [int]$proc.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentKey)) {
            $childrenByParent[$parentKey] = [System.Collections.Generic.List[object]]::new()
        }
        $childrenByParent[$parentKey].Add($proc)
    }

    $tree  = [System.Collections.Generic.List[int]]::new()
    $seen  = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $null  = $seen.Add($ProcessId)
    $tree.Add($ProcessId)
    $queue.Enqueue($ProcessId)

    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parentId)) { continue }
        $parentProc = $byId[$parentId]
        foreach ($child in $childrenByParent[$parentId]) {
            $childId = [int]$child.ProcessId
            if ($childId -eq $parentId -or $seen.Contains($childId)) { continue }
            if ($parentProc -and $parentProc.CreationDate -and $child.CreationDate -and
                $child.CreationDate -lt $parentProc.CreationDate) { continue }
            $null = $seen.Add($childId)
            $tree.Add($childId)
            $queue.Enqueue($childId)
        }
    }
    return $tree.ToArray()
}

# Of the processes listening on $Port, the ones whose PID is in $Tree. Mirrors
# listeners_owned_by_tree(): a foreign process holding the port returns nothing,
# so it is never treated as ours.
function Get-OwnedListener {
    param([int[]]$Tree, [int]$Port)
    if (-not $Tree -or $Tree.Count -eq 0 -or $Port -le 0) { return @() }
    try {
        $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
    } catch {
        return @()
    }
    $owners = @($listening | Select-Object -ExpandProperty OwningProcess -Unique)
    $treeSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($t in $Tree) { $null = $treeSet.Add([int]$t) }
    $owned = [System.Collections.Generic.List[int]]::new()
    foreach ($owner in $owners) {
        if ($treeSet.Contains([int]$owner)) { $null = $owned.Add([int]$owner) }
    }
    return $owned.ToArray()
}

# The pure ownership decision (no side effects, so it is unit-testable on the
# windows-latest CI lane without terminating anything). Returns whether the
# recorded PID is live, whether we can PROVE we own it, and the PID set we would
# stop. Mirrors the gate in stop_owned_runtime.
function Test-RuntimeOwnership {
    param(
        [int]$RecordedPid,
        [int]$RecordedPort,
        [int]$PreferredPort,
        [string]$IdentityFile
    )

    $result = [pscustomobject]@{
        RecordedPidLive = $false
        Owned           = $false
        PidsToStop      = @()
    }

    if ($RecordedPid -le 0) { return $result }
    if (-not (Get-Process -Id $RecordedPid -ErrorAction SilentlyContinue)) { return $result }
    $result.RecordedPidLive = $true

    $tree = @(Get-DescendantTree -ProcessId $RecordedPid)
    $pids = [System.Collections.Generic.List[int]]::new()
    foreach ($t in $tree) { $null = $pids.Add([int]$t) }

    $identityFileExists = [bool]($IdentityFile -and (Test-Path $IdentityFile))

    $ports = [System.Collections.Generic.List[int]]::new()
    if ($RecordedPort -gt 0) { $null = $ports.Add($RecordedPort) }
    if ($PreferredPort -gt 0 -and $PreferredPort -ne $RecordedPort) { $null = $ports.Add($PreferredPort) }

    $owned = $false
    foreach ($port in $ports) {
        $ownedListeners = @(Get-OwnedListener -Tree $tree -Port $port)
        foreach ($owner in $ownedListeners) {
            if (-not $pids.Contains([int]$owner)) { $null = $pids.Add([int]$owner) }
        }
        # Legacy state (no identity file): proof falls back to the recorded tree
        # genuinely owning the listener. Once an identity token exists it is
        # authoritative, so this fallback is gated off (mirrors desktop-quit.sh).
        if ($ownedListeners.Count -gt 0 -and -not $identityFileExists) { $owned = $true }
    }

    if (Test-ProcessIdentityMatch -ProcessId $RecordedPid -IdentityFile $IdentityFile) {
        $owned = $true
    }

    $result.Owned = $owned
    $result.PidsToStop = $pids.ToArray()
    return $result
}

# Stop a recorded runtime ONLY when ownership is proven, then drop its state.
# A live-but-unprovable PID (recycled, or a foreign listener on the port) is
# left running and its state is treated as stale. Sets $script:ClosedAny /
# $script:StaleAny for the closing summary.
function Stop-OwnedRuntime {
    # ConfirmImpact=Low keeps this prompt-free under the default $ConfirmPreference
    # (High), so the unattended desktop:quit path never blocks; -WhatIf still works.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [string]$PidFile,
        [string]$PortFile,
        [string]$IdentityFile,
        [int]$PreferredPort = 0,
        [string[]]$ExtraStateFile = @()
    )

    $recordedPid = 0
    if ($PidFile -and (Test-Path $PidFile)) {
        $raw = Get-Content -Raw -Path $PidFile -ErrorAction SilentlyContinue
        if ($raw) { $null = [int]::TryParse($raw.Trim(), [ref]$recordedPid) }
    }
    $recordedPort = 0
    if ($PortFile -and (Test-Path $PortFile)) {
        $raw = Get-Content -Raw -Path $PortFile -ErrorAction SilentlyContinue
        if ($raw) { $null = [int]::TryParse($raw.Trim(), [ref]$recordedPort) }
    }

    $ownershipArgs = @{
        RecordedPid   = $recordedPid
        RecordedPort  = $recordedPort
        PreferredPort = $PreferredPort
        IdentityFile  = $IdentityFile
    }
    $decision = Test-RuntimeOwnership @ownershipArgs

    if ($decision.RecordedPidLive -and $decision.Owned) {
        # Stop children before parents (reverse the parent-first BFS order) so a
        # supervisor cannot respawn a child we already reaped.
        $ordered = @($decision.PidsToStop)
        [array]::Reverse($ordered)
        foreach ($target in $ordered) {
            if ($target -le 0 -or $target -eq $PID) { continue }
            if ($PSCmdlet.ShouldProcess("PID $target", 'Stop owned runtime process')) {
                Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
            }
        }
        # Settle, then sweep any straggler still alive in the PROVEN set only.
        for ($i = 0; $i -lt 3; $i++) {
            $alive = @($ordered | Where-Object { $_ -gt 0 -and (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
            if ($alive.Count -eq 0) { break }
            Start-Sleep -Milliseconds 400
            foreach ($target in $alive) {
                if ($target -eq $PID) { continue }
                if ($PSCmdlet.ShouldProcess("PID $target", 'Stop owned runtime process')) {
                    Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $script:ClosedAny = $true
    } elseif ($decision.RecordedPidLive) {
        # Live, but ownership is unprovable (recycled PID, or a foreign process
        # now holds the recorded port). Leave it running; only drop our state.
        $script:StaleAny = $true
    } elseif (($PidFile -and (Test-Path $PidFile)) -or ($PortFile -and (Test-Path $PortFile))) {
        $script:StaleAny = $true
    }

    $toRemove = [System.Collections.Generic.List[string]]::new()
    if ($PidFile)      { $toRemove.Add($PidFile) }
    if ($PortFile)     { $toRemove.Add($PortFile) }
    if ($IdentityFile) { $toRemove.Add($IdentityFile) }
    foreach ($extra in $ExtraStateFile) { if ($extra) { $toRemove.Add($extra) } }
    if ($toRemove.Count -gt 0) {
        Remove-Item -Force -ErrorAction SilentlyContinue -Path $toRemove.ToArray()
    }
}

# Depth-first kill of a process and its children, used only to close leftover
# host/Edge windows (matched by app identity above, not by port). Carries the
# same parent-PID-reuse guard as Get-DescendantTree.
function Stop-ProcessTree {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([int]$ProcessId)
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    $self     = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        if ($self -and $self.CreationDate -and $child.CreationDate -and
            $child.CreationDate -lt $self.CreationDate) { continue }
        Stop-ProcessTree -ProcessId ([int]$child.ProcessId)
    }
    if ($PSCmdlet.ShouldProcess("PID $ProcessId", 'Stop process tree')) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Load apps from JSON (preferred) or a placeholder record (template). Internal
# record per app: @{ name; slug; port; backend_port }.
function Get-ConfiguredApp {
    $configFile = Join-Path $PSScriptRoot 'app-it.config.json'
    $records = @()
    if (Test-Path $configFile) {
        $cfg = Get-Content -Raw -Path $configFile | ConvertFrom-Json
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
            $records += [pscustomobject]@{
                name         = $name
                slug         = $slug
                port         = [string]$a.port
                backend_port = $backend
            }
        }
    } else {
        $records += [pscustomobject]@{
            name         = '__APP_NAME__'
            slug         = '__APP_SLUG__'
            port         = '__PORT__'
            backend_port = $null
        }
    }
    return $records
}

# =============================================================================
# Main cleanup.
# =============================================================================
function Invoke-DesktopQuit {
    $apps = @(Get-ConfiguredApp)
    if ($apps.Count -eq 0) {
        Write-Error 'ERROR: no apps configured. Edit scripts\app-it.config.json.'
        exit 1
    }

    # Per-app runtime state mirrors the macOS layout but under %LOCALAPPDATA%:
    #   %LOCALAPPDATA%\app-it\<slug>\{server.pid,server.port,server.identity,...}
    $stateBase = Join-Path $env:LOCALAPPDATA 'app-it'

    $script:ClosedAny = $false
    $script:StaleAny  = $false

    foreach ($app in $apps) {
        $stateDir        = Join-Path $stateBase $app.slug
        $pidFile         = Join-Path $stateDir 'server.pid'
        $portFile        = Join-Path $stateDir 'server.port'
        $identityFile    = Join-Path $stateDir 'server.identity'
        $backendPidFile  = Join-Path $stateDir 'backend.pid'
        $backendPortFile = Join-Path $stateDir 'backend.port'
        $backendIdFile   = Join-Path $stateDir 'backend.identity'

        $preferredPort = 0
        if ($app.port) { $null = [int]::TryParse([string]$app.port, [ref]$preferredPort) }
        Stop-OwnedRuntime -PidFile $pidFile -PortFile $portFile -IdentityFile $identityFile -PreferredPort $preferredPort

        # Backend (multi-server), if configured. No Windows launcher writes
        # backend.identity yet, so this uses the legacy tree-owns-listener proof.
        if ($app.backend_port) {
            $backendPreferred = 0
            $null = [int]::TryParse([string]$app.backend_port, [ref]$backendPreferred)
            Stop-OwnedRuntime -PidFile $backendPidFile -PortFile $backendPortFile -IdentityFile $backendIdFile -PreferredPort $backendPreferred
        }
    }

    # --- Close leftover host / Edge windows ----------------------------------
    # Normal Quit disposes the Job Object and takes the tree with it; this only
    # catches a host that lost its job or an Edge-fallback window. Matched by app
    # identity (host .exe named after the app; Edge by its per-app user-data-dir),
    # NOT by recorded port, so there is no "stop a stranger on the port" hazard.
    foreach ($app in $apps) {
        $stateDir = Join-Path $stateBase $app.slug

        foreach ($proc in Get-Process -Name $app.name -ErrorAction SilentlyContinue) {
            Stop-ProcessTree -ProcessId $proc.Id
            $script:ClosedAny = $true
        }

        $profileDir = Join-Path $stateDir 'WebView2'
        $edgeProcs = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*--user-data-dir=$profileDir*" }
        foreach ($proc in $edgeProcs) {
            Stop-ProcessTree -ProcessId ([int]$proc.ProcessId)
            $script:ClosedAny = $true
        }
    }

    if ($script:ClosedAny -and $script:StaleAny) {
        Write-Host 'Stopped owned dev servers/windows and cleaned stale state.'
    } elseif ($script:ClosedAny) {
        Write-Host 'Stopped owned dev servers and open windows.'
    } elseif ($script:StaleAny) {
        Write-Host 'Cleaned stale app-it state; no owned server was running.'
    } else {
        Write-Host 'Nothing to stop - no servers were running.'
    }
}

# --- Entrypoint --------------------------------------------------------------
# Run the cleanup only when executed as a script. When dot-sourced (the Pester
# suite loads the ownership helpers that way) $MyInvocation.InvocationName is
# '.', so the cleanup does not fire and the functions can be tested directly.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DesktopQuit
}
