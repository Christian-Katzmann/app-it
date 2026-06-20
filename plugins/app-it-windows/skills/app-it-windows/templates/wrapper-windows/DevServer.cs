// Owns the dev-server process tree via a Win32 Job Object.
//
// THE SEAM (ADR 0005): the HOST owns the job, not run-template.ps1. A Job
// Object dies when the process that CREATED it exits, so a job made by the
// short-lived PowerShell launcher would close — and kill the server — the
// instant that script returned. Therefore the host creates the job and spawns
// the server into it. run-template.ps1 is only a thin bootstrap.
//
// The job is created with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, which gives us
// two things at once:
//   • Explicit Quit → Dispose() closes the handle → the WHOLE tree
//     (cmd → node → vite → esbuild workers) is reaped atomically and the port
//     is freed. No signal cascade, the Windows reading of macOS killServer().
//   • Orphan-safety → if the host crashes, the OS closes the handle for us and
//     the server can't leak. This is the deliberate trade vs macOS's setsid
//     daemon (which survives a full wrapper exit) — see ADR 0005 lifecycle
//     row 2. Whether a maintainer prefers a truly-detached daemon is deferred.

using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

namespace AppItWindows;

public sealed class DevServer : IDisposable
{
    private readonly IntPtr _job;
    private Process? _process;
    private bool _disposed;

    public DevServer()
    {
        _job = CreateJobObjectW(IntPtr.Zero, null);
        if (_job == IntPtr.Zero)
            throw new InvalidOperationException("CreateJobObject failed.");

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            },
        };

        int len = Marshal.SizeOf(info);
        IntPtr ptr = Marshal.AllocHGlobal(len);
        try
        {
            Marshal.StructureToPtr(info, ptr, fDeleteOld: false);
            if (!SetInformationJobObject(_job, JobObjectExtendedLimitInformation, ptr, (uint)len))
                throw new InvalidOperationException("SetInformationJobObject failed.");
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    /// Spawns `startCommand` through cmd.exe (so PATH shims like pnpm.cmd /
    /// npm.cmd resolve), with PORT + HOST in the environment, bound to
    /// workingDir, with no visible console window. Records server.pid /
    /// server.port / server.identity under stateDir, mirroring macOS
    /// run-template.sh.
    public void Start(string startCommand, string workingDir, int port, string stateDir)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            // /d skips any AutoRun script; /s + the outer quotes keep the whole
            // command intact; /c runs it then exits.
            Arguments = $"/d /s /c \"{startCommand}\"",
            WorkingDirectory = Directory.Exists(workingDir) ? workingDir : Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        psi.EnvironmentVariables["PORT"] = port.ToString();
        // Loopback only. A 0.0.0.0 listener trips the Defender Firewall prompt,
        // exactly as it does the macOS firewall (ADR 0005 / SKILL.md anti-pattern).
        // Frameworks that honor HOST bind here; run-template.ps1 also appends
        // an explicit --host 127.0.0.1 where the dev script accepts one.
        psi.EnvironmentVariables["HOST"] = "127.0.0.1";

        _process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start the dev server.");

        // Assign immediately. Children spawned after assignment inherit the job
        // (nested-job-aware on Windows 8+), so the whole tree stays contained.
        // TODO(maintainer): a CREATE_SUSPENDED → assign → resume sequence would
        // close the tiny race where the very first grandchild spawns before the
        // assign lands. Verifying the tree is fully reaped with no breakaway is
        // a deferred check (ADR 0005) — confirm on real hardware.
        if (!AssignProcessToJobObject(_job, _process.Handle))
            throw new InvalidOperationException("AssignProcessToJobObject failed.");

        Directory.CreateDirectory(stateDir);
        File.WriteAllText(Path.Combine(stateDir, "server.pid"), _process.Id.ToString());
        File.WriteAllText(Path.Combine(stateDir, "server.port"), port.ToString());

        // Ownership token: cmd.exe's creation time as an invariant UTC FILETIME,
        // the Windows reading of macOS run-template.sh's server.identity
        // (ps -o lstart=). desktop-quit.ps1 re-reads (Get-Process).StartTime and
        // refuses to stop the recorded PID unless this still matches, so a
        // recycled/foreign PID on the recorded port is left alone. Best-effort:
        // if StartTime is momentarily unreadable, quit falls back to the
        // tree-owns-listener proof, so a write failure here is non-fatal.
        try
        {
            File.WriteAllText(
                Path.Combine(stateDir, "server.identity"),
                _process.StartTime.ToFileTimeUtc().ToString(CultureInfo.InvariantCulture));
        }
        catch (Exception)
        {
            // Non-fatal — see above.
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        // Closing the job handle fires KILL_ON_JOB_CLOSE: the entire tree dies
        // and the port is freed. This is the explicit-Quit teardown path.
        if (_job != IntPtr.Zero) CloseHandle(_job);
        _process?.Dispose();
    }

    // ---- Win32 interop -----------------------------------------------------

    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob, int jobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
