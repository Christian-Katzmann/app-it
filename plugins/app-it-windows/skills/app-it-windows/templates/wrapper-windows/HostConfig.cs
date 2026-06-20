// Immutable launch parameters, resolved from --flags first then env vars.
//
// run-template.ps1 (step 2.3) is a THIN bootstrap: it augments PATH, scans a
// free port on 127.0.0.1, resolves the dev-server START_COMMAND, then launches
// this host with the result. Nothing here is baked into the .exe — the host is
// generic and the launcher supplies everything per run. That keeps the single
// published .exe reusable across apps (the build copies, never recompiles).

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace AppItWindows;

public sealed class HostConfig
{
    public string? Url { get; init; }
    public string Title { get; init; } = "App";
    public string? IconPath { get; init; }
    public string Slug { get; init; } = "app";

    /// The dev-server port. Null for W-Static (a file:// URL, no server).
    public int? Port { get; init; }

    /// The dev-server command, e.g. "pnpm exec next dev". Null/empty when there
    /// is no server to launch (W-Static).
    public string? StartCommand { get; init; }

    /// PROJECT_ROOT the dev server is spawned in (honors APP_IT_PROJECT_ROOT
    /// upstream in run-template.ps1; never derived from the .exe path).
    public string? WorkingDir { get; init; }

    /// %LOCALAPPDATA%\app-it\<slug>\ — per-app state/log namespace, the Windows
    /// analog of macOS's ~/Library/Application Support/app-it/<slug>/. Holds
    /// server.pid / server.port / server.identity (written when the server
    /// starts; the identity token lets desktop-quit.ps1 prove ownership).
    public string StateDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "app-it", Slug);

    /// WebView2's isolated profile (cache, localStorage, cookies, IndexedDB)
    /// lives under the per-app state dir so apps never share a browser profile.
    /// Default: %LOCALAPPDATA%\app-it\<slug>\WebView2.
    public string WebView2UserDataDir => Path.Combine(StateDir, "WebView2");

    public static HostConfig Resolve(string[] args)
    {
        Dictionary<string, string> flags = ParseFlags(args);

        string? Pick(string flag, string env)
        {
            if (flags.TryGetValue(flag, out var v) && !string.IsNullOrWhiteSpace(v))
                return v;
            var fromEnv = Environment.GetEnvironmentVariable(env);
            return string.IsNullOrWhiteSpace(fromEnv) ? null : fromEnv;
        }

        var url = Pick("url", "APP_IT_URL");
        if (url is null)
        {
            // Positional fallback: the first bare arg is the URL, mirroring
            // wrapper.swift's `wrapper <url> [app-name] ...` positional contract.
            var positional = args.FirstOrDefault(
                a => !a.StartsWith("--", StringComparison.Ordinal));
            if (!string.IsNullOrWhiteSpace(positional)) url = positional;
        }

        var title = Pick("title", "APP_IT_TITLE") ?? "App";
        var portRaw = Pick("port", "APP_IT_PORT");
        int? port = int.TryParse(portRaw, out var p) && p > 0 ? p : null;

        return new HostConfig
        {
            Url = url,
            Title = title,
            IconPath = Pick("icon", "APP_IT_ICON"),
            Slug = Slugify(Pick("slug", "APP_IT_SLUG") ?? title),
            Port = port,
            StartCommand = Pick("start-command", "APP_IT_START_COMMAND"),
            WorkingDir = Pick("working-dir", "APP_IT_WORKING_DIR"),
        };
    }

    /// Accepts `--key value` and `--key=value`. Bare positionals are ignored
    /// here (handled separately for the URL fallback).
    private static Dictionary<string, string> ParseFlags(string[] args)
    {
        var flags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            if (!a.StartsWith("--", StringComparison.Ordinal)) continue;
            var key = a[2..];
            var eq = key.IndexOf('=');
            if (eq >= 0)
            {
                flags[key[..eq]] = key[(eq + 1)..];
            }
            else if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                flags[key] = args[++i];
            }
            else
            {
                flags[key] = "true"; // bare boolean flag
            }
        }
        return flags;
    }

    /// Lowercase, ASCII, dashes — safe for a folder name under %LOCALAPPDATA%.
    private static string Slugify(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool lastDash = false;
        foreach (var ch in s.Trim().ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch) && ch < 128)
            {
                sb.Append(ch);
                lastDash = false;
            }
            else if (!lastDash && sb.Length > 0)
            {
                sb.Append('-');
                lastDash = true;
            }
        }
        var slug = sb.ToString().Trim('-');
        return slug.Length == 0 ? "app" : slug;
    }
}
