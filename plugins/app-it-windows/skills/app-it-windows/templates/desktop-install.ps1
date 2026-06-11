# macOS sibling: desktop-install.sh — installs every built launcher into the
#   user's app folder. (macOS: copies desktop\*.app into ~/Applications/App It/,
#   a Dock Stack. Windows: creates a Start Menu .lnk per app under an "app-it"
#   Programs folder — the Windows equivalent of that one-folder Dock Stack.)
#
# Windows beta · scaffolded · untested on real hardware · maintainer wanted.
#
# Per ADR 0005 the shortcut lands at:
#   %APPDATA%\Microsoft\Windows\Start Menu\Programs\app-it\<App Name>.lnk
# created with the WScript.Shell COM object. The folder ("app-it") is the
# Windows reading of ~/Applications/App It/.
#
# Honors APP_IT_INSTALL_DIR — same override the macOS install script honors —
# to redirect the install target (e.g. a Desktop folder or a custom Start Menu
# subfolder).
#
# The .lnk targets PowerShell running the per-app run.ps1 (the thin bootstrap),
# NOT the host .exe directly: run.ps1 augments PATH, pre-flights, and scans for
# a free port before handing off to the host (ADR 0005). -WindowStyle Hidden
# keeps the console from showing; a brief flash on slow machines is a documented
# beta wart a maintainer may resolve (e.g. a .vbs shim or conhost tweak).
#
# MAINTAINER (ADR 0005 deferred list): confirm the .lnk lands in the Start Menu,
# its icon renders in taskbar + Start (Windows icon-cache quirks), and SmartScreen
# "Run anyway" sticks on first launch.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = if ($env:APP_IT_PROJECT_ROOT) { $env:APP_IT_PROJECT_ROOT } else { (Resolve-Path (Join-Path $ScriptDir '..')).Path }

$ConfigFile = Join-Path $ScriptDir 'app-it.config.json'

# Per-app Start Menu folder. app-it.config.example.json documents
# platform.windows.start_menu_folder as configurable (default "app-it"); read it
# here so the field actually takes effect (it was previously ignored). The folder
# is resolved per app in the loop below. APP_IT_INSTALL_DIR still overrides
# everything with a single explicit target for all apps, exactly as before.
$defaultFolder = 'app-it'
$folderForApp  = @{}
if (Test-Path $ConfigFile) {
    $cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
    foreach ($a in $cfg.apps) {
        $folder = $defaultFolder
        if ($a.PSObject.Properties.Name -contains 'platform' -and $a.platform -and
            $a.platform.PSObject.Properties.Name -contains 'windows' -and $a.platform.windows -and
            $a.platform.windows.PSObject.Properties.Name -contains 'start_menu_folder' -and
            $a.platform.windows.start_menu_folder) {
            $folder = [string]$a.platform.windows.start_menu_folder
        }
        if ($a.name) { $folderForApp[[string]$a.name] = $folder }
    }
}

$programsBase   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$overrideTarget = $env:APP_IT_INSTALL_DIR
if ($overrideTarget -and -not (Test-Path $overrideTarget)) {
    Write-Error "Install target $overrideTarget does not exist."
    exit 1
}

# Prefer PowerShell 7 (pwsh) if present, else Windows PowerShell.
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }

$desktop = Join-Path $Root 'desktop'
if (-not (Test-Path $desktop)) {
    Write-Error "No desktop\ folder under $Root. Run desktop-build.ps1 first."
    exit 1
}

$wsh = New-Object -ComObject WScript.Shell
$count = 0
foreach ($appDir in Get-ChildItem -Path $desktop -Directory -ErrorAction SilentlyContinue) {
    $runScript = Join-Path $appDir.FullName 'run.ps1'
    if (-not (Test-Path $runScript)) {
        Write-Warning "  skipping $($appDir.Name): no run.ps1 (re-run desktop-build.ps1)."
        continue
    }

    $folder = if ($folderForApp.ContainsKey($appDir.Name)) { $folderForApp[$appDir.Name] } else { $defaultFolder }
    $target = if ($overrideTarget) { $overrideTarget } else { Join-Path $programsBase $folder }
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-Host "Created $target."
    }

    $lnkPath = Join-Path $target "$($appDir.Name).lnk"
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath       = $pwshExe
    $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""
    $sc.WorkingDirectory = $appDir.FullName
    $sc.Description      = "$($appDir.Name) (app-it)"

    # Icon: the per-app .ico if the icon step produced one; else the host .exe
    # (its embedded icon); else leave PowerShell's default.
    $ico = Join-Path $appDir.FullName "$($appDir.Name).ico"
    $exe = Join-Path $appDir.FullName "$($appDir.Name).exe"
    if (Test-Path $ico)      { $sc.IconLocation = "$ico,0" }
    elseif (Test-Path $exe)  { $sc.IconLocation = "$exe,0" }

    $sc.Save()
    Write-Host "Installed: $lnkPath"
    $count++
}
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null

if ($count -eq 0) {
    Write-Error "No app folders found under $desktop. Run desktop-build.ps1 first."
    exit 1
}

Write-Host ''
Write-Host "Installed $count shortcut(s). Right-click any one in the Start Menu to pin it to Start or the taskbar."
