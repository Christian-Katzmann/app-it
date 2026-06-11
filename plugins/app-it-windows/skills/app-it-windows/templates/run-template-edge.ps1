# macOS sibling: run-template-chrome.sh — the browser --app fallback launcher,
#   used when the native shell is unavailable or the app needs Chromium-only
#   Web APIs. (macOS uses Chrome --app; Windows uses Edge --app.)
#
# Windows beta · scaffolded · untested on real hardware · maintainer wanted.
#
# Used when:
#   1. The .NET SDK / WebView2 runtime is unavailable (can't build/run the WPF
#      host), OR
#   2. The app needs FSA real-I/O or other Chromium-only Web APIs.
#
# OWNERSHIP OF THE JOB OBJECT (ADR 0005): in the normal path the WPF host owns
# the Job Object and spawns the dev server into it. In THIS fallback there is no
# host, so run-template-edge.ps1 owns the Job Object itself. The job is created
# with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so when this script exits the whole
# dev-server tree is reaped atomically. Because a Job Object dies with its
# creating process, the server's lifetime is bound to THIS script: the script
# stays alive while Edge is open and tears the server down when Edge exits.
# This is the orphan-safe trade ADR 0005 picks for the beta (lifecycle row 2) -
# it does NOT keep the server warm across window-close the way macOS does.
# desktop-quit.ps1 is the defensive shutdown for any orphan that slips through.
#
# 127.0.0.1 vs 0.0.0.0 (OPEN QUESTION, same shape as macOS): we bind/probe the
# loopback interface only and export HOST=127.0.0.1. A non-loopback (0.0.0.0 /
# LAN) listener trips the Windows Defender Firewall "allow access?" dialog on
# first run - the exact Windows analog of the macOS firewall prompt. Loopback
# never prompts. A local launcher has no reason to be reachable off-box, so
# loopback-only is correct here.
#
# Substituted by desktop-build.ps1 - see run-template.ps1 for placeholder docs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AppName      = '__APP_NAME__'
$AppSlug      = '__APP_SLUG__'
$ProjectRoot  = '__PROJECT_ROOT__'
$PreferredPort = [int]'__PORT__'
$StartCommand = '__START_COMMAND__'

$StateDir = Join-Path $env:LOCALAPPDATA "app-it\$AppSlug"
$LogDir   = Join-Path $env:LOCALAPPDATA "app-it\$AppSlug\logs"
New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
$ServerLog = Join-Path $LogDir 'server.log'
$PidFile   = Join-Path $StateDir 'server.pid'
$PortFile  = Join-Path $StateDir 'server.port'
# Ownership token re-checked by desktop-quit.ps1 (mirrors macOS server.identity).
$IdFile    = Join-Path $StateDir 'server.identity'
# NB: not $Profile — that's a PowerShell automatic variable. This is the
# WebView2 user-data dir, kept identical to desktop-quit.ps1's match key.
$ProfileDir = Join-Path $StateDir 'WebView2'
New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

# Loaded up front: the project-root sanity check below shows a MessageBox on
# failure, so the assembly must be present before that path can run.
Add-Type -AssemblyName System.Windows.Forms

# --- PATH augmentation -------------------------------------------------------
# A Start-Menu / double-click launch starts with a bare PATH. Cover the version
# managers Windows devs actually use (ADR 0005, lifecycle row 1 - a maintainer
# confirms the real-world set): nvm-windows, fnm, Volta, Scoop shims, pnpm.
$pathParts = @(
    (Join-Path $env:APPDATA 'nvm'),
    (Join-Path $env:LOCALAPPDATA 'fnm_multishells'),
    (Join-Path $env:LOCALAPPDATA 'Volta\bin'),
    (Join-Path $env:USERPROFILE 'scoop\shims'),
    (Join-Path $env:LOCALAPPDATA 'pnpm'),
    "$env:ProgramFiles\nodejs"
) | Where-Object { Test-Path $_ }
if ($pathParts) { $env:Path = ($pathParts -join ';') + ';' + $env:Path }

# Loopback-only: many dev servers honor HOST. See header note.
$env:HOST = '127.0.0.1'

# --- Project-root sanity -----------------------------------------------------
if (-not (Test-Path $ProjectRoot)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Project repo not found at:`n$ProjectRoot`n`nThe launcher was built against a path that no longer exists. Re-run the build from the canonical repo location.",
        "$AppName failed to launch") | Out-Null
    exit 1
}

# --- Pre-flight: required binary present? -------------------------------------
$firstBin = ($StartCommand -split '\s+')[0]
if ($firstBin -and -not (Get-Command $firstBin -ErrorAction SilentlyContinue)) {
    Write-Error "Required binary not found on PATH: $firstBin"
    exit 1
}

# --- Pre-flight: node_modules present? ---------------------------------------
if ($StartCommand -match '^(npm|pnpm|yarn|bun|bunx|npx)\b') {
    if (-not (Test-Path (Join-Path $ProjectRoot 'node_modules'))) {
        Write-Error "node_modules is missing in $ProjectRoot. Run an install there, then click again."
        exit 1
    }
}

# --- Loopback free-port probe ------------------------------------------------
# ADR 0005: a TcpListener bind-probe on 127.0.0.1 is more reliable than reading
# Get-NetTCPConnection (which only lists *existing* connections). We actually
# bind to claim the port is free, then immediately release it before the dev
# server binds. Small TOCTOU window, acceptable for a local launcher.
function Test-PortFree {
    param([int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); return $true } catch { return $false } finally { $listener.Stop() }
}

# --- Stale-state cleanup -----------------------------------------------------
if (Test-Path $PidFile) {
    $recorded = (Get-Content -Raw $PidFile).Trim()
    if (-not $recorded -or -not (Get-Process -Id $recorded -ErrorAction SilentlyContinue)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $PidFile, $PortFile, $IdFile
    }
}

# --- Job Object P/Invoke -----------------------------------------------------
# KILL_ON_JOB_CLOSE => the whole tree dies when the job handle closes (i.e.
# when this script's process exits). Nested-job aware on Win8+, so
# npm -> node -> vite -> esbuild workers stay inside the job.
if (-not ('AppIt.Win32Job' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace AppIt {
  public static class Win32Job {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr a, string lpName);
    [DllImport("kernel32.dll")]
    public static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cb);
    [DllImport("kernel32.dll")]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
      public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong r, w, o, rb, wb, ob; }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
      public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
      public IO_COUNTERS IoInfo;
      public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    public static IntPtr CreateKillOnCloseJob() {
      IntPtr job = CreateJobObject(IntPtr.Zero, null);
      var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      ext.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      int len = Marshal.SizeOf(ext);
      IntPtr p = Marshal.AllocHGlobal(len);
      try {
        Marshal.StructureToPtr(ext, p, false);
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, p, (uint)len);
      } finally { Marshal.FreeHGlobal(p); }
      return job;
    }
  }
}
'@
}

# --- Allocate a free port + start the server inside the job ------------------
$chosenPort = $null
for ($p = $PreferredPort; $p -le ($PreferredPort + 50); $p++) {
    if (Test-PortFree -Port $p) { $chosenPort = $p; break }
}
if (-not $chosenPort) {
    [System.Windows.Forms.MessageBox]::Show(
        "Searched $PreferredPort-$($PreferredPort + 50). Quit something using one of those ports and try again.",
        "$AppName couldn't find a free port") | Out-Null
    exit 1
}

$job = [AppIt.Win32Job]::CreateKillOnCloseJob()

# Spawn the dev server via cmd so START_COMMAND can be any shell line, with
# PORT + HOST in the environment. Detached console, output to the server log.
$env:PORT = "$chosenPort"
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $env:ComSpec   # cmd.exe
# /s + ONE outer quote pair, inner path quotes doubled. Without /s, cmd strips
# the first and last quote of a command line that contains a redirect, turning
# `"node ..." > "log"` into `node ..." > "log` (a stray quote), so the server
# never starts and no log is written. /s says "use everything between the first
# and last quote verbatim", so the whole pipeline must live inside that one pair.
$psi.Arguments = "/s /c `"$StartCommand > `"`"$ServerLog`"`" 2>&1`""
$psi.WorkingDirectory = $ProjectRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$server = [System.Diagnostics.Process]::Start($psi)
[AppIt.Win32Job]::AssignProcessToJobObject($job, $server.Handle) | Out-Null

Set-Content -Path $PidFile  -Value $server.Id
Set-Content -Path $PortFile -Value $chosenPort
# Ownership token: cmd.exe's creation time as an invariant UTC FILETIME, the
# Windows reading of macOS run-template.sh's server.identity (ps -o lstart=).
# desktop-quit.ps1 re-reads (Get-Process).StartTime and only stops the recorded
# PID when this still matches, so a recycled/foreign PID survives. Best-effort:
# if StartTime is unreadable, quit falls back to the tree-owns-listener proof.
try {
    Set-Content -Path $IdFile -Value $server.StartTime.ToFileTimeUtc().ToString([System.Globalization.CultureInfo]::InvariantCulture)
} catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $IdFile
}

$url = "http://127.0.0.1:$chosenPort"

# --- Two-stage readiness probe (port-bound -> any HTTP) ----------------------
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    if (-not (Test-PortFree -Port $chosenPort)) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}
if ($ready) {
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
            $ready = $true; break
        } catch {
            # Any HTTP status (incl. 4xx/5xx) means the server answered.
            if ($_.Exception.Response) { $ready = $true; break }
        }
        Start-Sleep -Milliseconds 500
    }
}
if (-not $ready) {
    $tail = if (Test-Path $ServerLog) { (Get-Content -Tail 40 $ServerLog) -join "`n" } else { '(no log)' }
    Remove-Item -Force -ErrorAction SilentlyContinue $PidFile, $PortFile, $IdFile
    [System.Windows.Forms.MessageBox]::Show(
        "The dev server did not bind to $url within 60s.`n`nLast log lines:`n$tail",
        "$AppName failed to start") | Out-Null
    exit 1
}

# --- Open in Edge --app (Chromium app-mode) ----------------------------------
$edgeCandidates = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ }

if (-not $edgeCandidates) {
    # Last resort: default browser. No chromeless window, FSA support unverified.
    Start-Process $url
    # Without Edge we can't anchor the window's lifetime; keep the job alive
    # until the user runs desktop-quit.ps1.
    Write-Host "Edge not found - opened $url in the default browser. Run desktop-quit.ps1 to stop the server."
    # Hold the job open by waiting on the server process.
    $server.WaitForExit()
    exit 0
}

$edge = Start-Process -FilePath $edgeCandidates[0] `
    -ArgumentList "--app=$url", "--user-data-dir=$ProfileDir" -PassThru

# Block on Edge so THIS process (and thus the job) stays alive while the window
# is open. When Edge closes, the script exits, the job handle closes, and
# KILL_ON_JOB_CLOSE reaps the dev-server tree. Orphan-safe; not warm-kept.
$edge.WaitForExit()
Remove-Item -Force -ErrorAction SilentlyContinue $PidFile, $PortFile, $IdFile
