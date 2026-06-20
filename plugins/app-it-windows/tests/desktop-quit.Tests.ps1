# Behavioral test for desktop-quit.ps1's cleanup ownership proof.
#
# Windows beta - scaffolded - maintainer wanted. This runs on the windows-latest
# CI lane (the .ps1 cannot be exercised on the author's macOS). It proves the
# ownership DECISION and the stop path against REAL processes on REAL Windows.
# The full end-to-end (a real npm -> node -> vite tree, Job Object reap, taskbar
# identity, tray UX) still needs a Windows maintainer - see docs/WINDOWS.md.
#
# Nothing here stops a process it did not spawn; the whole point is to prove that
# a process we cannot prove we own is LEFT RUNNING. Every spawned helper is
# reaped in a finally block.
#
# We dot-source desktop-quit.ps1 to load its ownership helpers. The script's
# entrypoint is guarded against dot-sourcing, so loading it does not run cleanup.

BeforeAll {
    $quitScript = Join-Path $PSScriptRoot '..\skills\app-it-windows\templates\desktop-quit.ps1'
    . $quitScript

    # A real, disposable process we own. Start-Sleep keeps it alive; it spawns no
    # children, so its descendant tree is just itself.
    function New-Sleeper {
        $p = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        )
        Start-Sleep -Milliseconds 300   # let StartTime settle and the PID register
        return $p
    }

    function Stop-Sleeper {
        param($Proc)
        if ($Proc) { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue }
    }

    function Wait-Dead {
        param([int]$ProcessId)
        for ($i = 0; $i -lt 60; $i++) {
            if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }
            Start-Sleep -Milliseconds 100
        }
    }

    # A real process that binds an OS-assigned loopback port and reports it via a
    # temp file, so the test learns the (guaranteed-free) port without a race.
    function Start-LoopbackListener {
        $portFile = Join-Path ([System.IO.Path]::GetTempPath()) ("app-it-lp-" + [guid]::NewGuid().ToString('N') + ".txt")
        $inner = "`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); `$l.Start(); ([System.Net.IPEndPoint]`$l.LocalEndpoint).Port | Set-Content -LiteralPath '$portFile'; Start-Sleep -Seconds 30"
        $p = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', $inner)
        $port = 0
        for ($i = 0; $i -lt 100; $i++) {
            if (Test-Path -LiteralPath $portFile) {
                $raw = Get-Content -Raw -LiteralPath $portFile -ErrorAction SilentlyContinue
                if ($raw -and [int]::TryParse($raw.Trim(), [ref]$port) -and $port -gt 0) { break }
            }
            Start-Sleep -Milliseconds 100
        }
        Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400   # let the LISTEN socket surface in the TCP table
        return [pscustomobject]@{ Process = $p; Port = $port }
    }

    function New-IdentityFile {
        param([string]$Content)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("app-it-id-" + [guid]::NewGuid().ToString('N') + ".identity")
        Set-Content -LiteralPath $path -Value $Content
        return $path
    }
}

Describe 'Get-ProcessIdentity / Test-ProcessIdentityMatch' {
    It 'matches a live PID against its own recorded identity token' {
        $p = New-Sleeper
        try {
            $idFile = New-IdentityFile -Content (Get-ProcessIdentity -ProcessId $p.Id)
            Test-ProcessIdentityMatch -ProcessId $p.Id -IdentityFile $idFile | Should -BeTrue
        } finally {
            Stop-Sleeper -Proc $p
        }
    }

    It 'does NOT match when the recorded token is foreign (the recycled-PID case)' {
        $p = New-Sleeper
        try {
            $idFile = New-IdentityFile -Content '1'   # cannot be this process's creation time
            Test-ProcessIdentityMatch -ProcessId $p.Id -IdentityFile $idFile | Should -BeFalse
        } finally {
            Stop-Sleeper -Proc $p
        }
    }

    It 'does NOT match when there is no identity file (legacy state)' {
        $p = New-Sleeper
        try {
            Test-ProcessIdentityMatch -ProcessId $p.Id -IdentityFile '' | Should -BeFalse
        } finally {
            Stop-Sleeper -Proc $p
        }
    }
}

Describe 'Test-RuntimeOwnership' {
    It 'reports Owned when the identity token matches the live recorded PID' {
        $p = New-Sleeper
        try {
            $idFile = New-IdentityFile -Content (Get-ProcessIdentity -ProcessId $p.Id)
            $d = Test-RuntimeOwnership -RecordedPid $p.Id -RecordedPort 0 -PreferredPort 0 -IdentityFile $idFile
            $d.RecordedPidLive | Should -BeTrue
            $d.Owned           | Should -BeTrue
            $d.PidsToStop      | Should -Contain $p.Id
        } finally {
            Stop-Sleeper -Proc $p
        }
    }

    It 'reports NOT Owned for a live PID with a foreign token, and the process survives' {
        $p = New-Sleeper
        try {
            $idFile = New-IdentityFile -Content '1'   # forged / recycled token
            $d = Test-RuntimeOwnership -RecordedPid $p.Id -RecordedPort 0 -PreferredPort 0 -IdentityFile $idFile
            $d.RecordedPidLive | Should -BeTrue
            $d.Owned           | Should -BeFalse
            Get-Process -Id $p.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } finally {
            Stop-Sleeper -Proc $p
        }
    }

    It 'reports NOT Owned (stale) for a dead recorded PID' {
        $p = New-Sleeper
        $deadPid = $p.Id
        Stop-Process -Id $deadPid -Force
        Wait-Dead -ProcessId $deadPid
        $d = Test-RuntimeOwnership -RecordedPid $deadPid -RecordedPort 0 -PreferredPort 0 -IdentityFile ''
        $d.RecordedPidLive | Should -BeFalse
        $d.Owned           | Should -BeFalse
    }

    It 'proves legacy ownership (no identity file) when the recorded PID owns the listener' {
        $listener = Start-LoopbackListener
        try {
            $listener.Port | Should -BeGreaterThan 0
            $d = Test-RuntimeOwnership -RecordedPid $listener.Process.Id -RecordedPort $listener.Port -PreferredPort 0 -IdentityFile ''
            $d.RecordedPidLive | Should -BeTrue
            $d.Owned           | Should -BeTrue
        } finally {
            Stop-Sleeper -Proc $listener.Process
        }
    }

    It 'does NOT prove ownership when a FOREIGN process owns the recorded port' {
        $listener = Start-LoopbackListener
        $other = New-Sleeper
        try {
            $listener.Port | Should -BeGreaterThan 0
            # Recorded PID is an unrelated sleeper; the port is held by a process
            # outside its tree, and there is no identity file -> neither proof holds.
            $d = Test-RuntimeOwnership -RecordedPid $other.Id -RecordedPort $listener.Port -PreferredPort 0 -IdentityFile ''
            $d.Owned | Should -BeFalse
            Get-Process -Id $listener.Process.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } finally {
            Stop-Sleeper -Proc $listener.Process
            Stop-Sleeper -Proc $other
        }
    }
}

Describe 'Stop-OwnedRuntime (end-to-end)' {
    It 'stops an owned process and removes its state files' {
        $p = New-Sleeper
        $targetPid = $p.Id
        try {
            $dir      = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            $pidFile  = Join-Path $dir.FullName 'server.pid'
            $portFile = Join-Path $dir.FullName 'server.port'
            $idFile   = Join-Path $dir.FullName 'server.identity'
            Set-Content -LiteralPath $pidFile  -Value $targetPid
            Set-Content -LiteralPath $portFile -Value '0'
            Set-Content -LiteralPath $idFile   -Value (Get-ProcessIdentity -ProcessId $targetPid)

            Stop-OwnedRuntime -PidFile $pidFile -PortFile $portFile -IdentityFile $idFile -Confirm:$false

            Wait-Dead -ProcessId $targetPid
            Get-Process -Id $targetPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Test-Path $pidFile  | Should -BeFalse
            Test-Path $portFile | Should -BeFalse
            Test-Path $idFile   | Should -BeFalse
        } finally {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
        }
    }

    It 'leaves a foreign-identity PID running while clearing the stale state' {
        $p = New-Sleeper
        $targetPid = $p.Id
        try {
            $dir      = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            $pidFile  = Join-Path $dir.FullName 'server.pid'
            $portFile = Join-Path $dir.FullName 'server.port'
            $idFile   = Join-Path $dir.FullName 'server.identity'
            Set-Content -LiteralPath $pidFile  -Value $targetPid
            Set-Content -LiteralPath $portFile -Value '0'
            Set-Content -LiteralPath $idFile   -Value '1'   # forged token -> not ours

            Stop-OwnedRuntime -PidFile $pidFile -PortFile $portFile -IdentityFile $idFile -Confirm:$false

            # The acceptance criterion: a process we can't prove we own survives.
            Get-Process -Id $targetPid -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            # ...but the stale state is cleared.
            Test-Path $pidFile | Should -BeFalse
            Test-Path $idFile  | Should -BeFalse
        } finally {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
        }
    }
}
