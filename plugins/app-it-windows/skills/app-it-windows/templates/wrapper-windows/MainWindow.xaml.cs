// The window + WebView2 host. This is the heart of the Windows shell, the
// counterpart to AppDelegate in wrapper.swift.
//
// It manufactures the soft-close-vs-quit distinction Windows does NOT give for
// free (ADR 0005 lifecycle row 3), with the three wired pieces:
//   1. ShutdownMode = OnExplicitShutdown   (set in App.xaml)
//   2. Closing / minimize  → e.Cancel = true → hide to tray   (server stays warm)
//   3. tray "Quit"         → dispose the Job Object → server dies, port freed
//
// Everything a Mac can author is here; everything that needs real Windows
// hardware to confirm (window actually renders, taskbar identity, tray UX,
// Job-Object reap, DPI) is the deferred-to-maintainer list in ADR 0005.

using System;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace AppItWindows;

public partial class MainWindow : Window
{
    private readonly HostConfig _config;
    private Forms.NotifyIcon? _tray;
    private DevServer? _server;
    private bool _quitting;
    private bool _trayHintShown;

    // Microsoft's canonical WebView2 download page (the "Evergreen Standalone"
    // installer). Windows LTSC/Server and some clean installs ship without the
    // runtime; this is where an end user gets it. Locale-neutral — Microsoft
    // redirects to the user's region.
    private const string WebView2DownloadUrl =
        "https://developer.microsoft.com/microsoft-edge/webview2/";

    public MainWindow(HostConfig config)
    {
        _config = config;
        InitializeComponent();

        Title = config.Title;
        ApplyIcon();
        SetupTray();

        Loaded += OnLoaded;
    }

    // ---- Startup -----------------------------------------------------------

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            // Isolated per-app WebView2 profile under %LOCALAPPDATA%\app-it\<slug>\.
            var env = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: _config.WebView2UserDataDir);
            await Web.EnsureCoreWebView2Async(env);

            // External (non-loopback) links open in the user's default browser,
            // mirroring wrapper.swift's decidePolicyFor host check. Loopback
            // navigation stays in-window.
            Web.CoreWebView2.NavigationStarting += KeepLoopbackInWindow;
            Web.CoreWebView2.NewWindowRequested += OpenInNewWindowExternally;

            // Pin the window title to the configured app name. WebView2
            // auto-syncs Window.Title to the page's <title> tag via
            // DocumentTitleChanged, which overwrites the --title value.
            // macOS doesn't have this problem (NSWindow.title is independent
            // of WKWebView), so this handler is the Windows-specific fix.
            Web.CoreWebView2.DocumentTitleChanged += (_, _) => Title = _config.Title;

            // Spawn the dev server into the host-owned Job Object, then wait for
            // the port to answer so the first paint is the app, not an error
            // page. W-Static has no StartCommand/Port — skip straight to Navigate.
            if (!string.IsNullOrWhiteSpace(_config.StartCommand) && _config.Port is int port)
            {
                _server = new DevServer();
                _server.Start(
                    _config.StartCommand!,
                    _config.WorkingDir ?? Environment.CurrentDirectory,
                    port,
                    _config.StateDir);
                await WaitForServerAsync(_config.Url!);
            }

            Web.CoreWebView2.Navigate(_config.Url!);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            // The Evergreen runtime is genuinely absent (common on Windows
            // LTSC / Server, which ship without Edge). This is the one failure
            // an end user can fix themselves, so offer to open the download
            // page instead of leaving them at a dead window. Caught separately
            // from the generic handler below so we only point at the installer
            // when that is actually the problem.
            var open = MessageBox.Show(
                $"{_config.Title} needs the Microsoft Edge WebView2 runtime, " +
                "which isn't installed on this PC.\n\n" +
                "Click Yes to open the Microsoft download page. Install the " +
                "\"Evergreen Standalone\" runtime, then relaunch.",
                _config.Title, MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (open == MessageBoxResult.Yes) OpenInDefaultBrowser(WebView2DownloadUrl);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "WebView2 failed to start.\n\n" + ex.Message + "\n\n" +
                "If the Microsoft Edge WebView2 runtime is missing, install it from\n" +
                WebView2DownloadUrl + "\nthen relaunch. See docs/WINDOWS.md for the " +
                "maintainer checklist.",
                _config.Title, MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    /// Poll the URL until the listener answers (any HTTP response) or we hit the
    /// timeout. Keeps the cold-start first paint clean instead of flashing a
    /// connection-refused page while the dev server boots.
    private static async System.Threading.Tasks.Task WaitForServerAsync(
        string url, int timeoutSeconds = 40)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
                return; // a response of any kind means the server is listening
            }
            catch
            {
                await System.Threading.Tasks.Task.Delay(200);
            }
        }
    }

    // ---- External-link routing --------------------------------------------

    private void KeepLoopbackInWindow(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri)) return;
        if (uri.Scheme is not ("http" or "https")) return; // file:// etc. stays in-window
        if (IsLoopback(uri)) return;
        e.Cancel = true;
        OpenInDefaultBrowser(uri.ToString());
    }

    private void OpenInNewWindowExternally(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true; // never spawn a second WebView2 window
        OpenInDefaultBrowser(e.Uri);
    }

    private static bool IsLoopback(Uri uri) =>
        uri.Host is "localhost" or "127.0.0.1" or "[::1]" ||
        uri.Host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase);

    private static void OpenInDefaultBrowser(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // No default browser / malformed URL — silently ignore.
        }
    }

    // ---- Lifecycle: soft-close vs quit ------------------------------------

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_quitting)
        {
            base.OnClosing(e);
            return;
        }

        // Soft-close: X / Alt+F4 cancels the close and hides to the tray. The
        // dev server stays warm in its Job Object. Explicit Quit (tray menu) is
        // the ONLY path that tears the server down.
        // DEFERRED (ADR 0005): whether silent X-to-tray matches Windows users'
        // expectations, and whether tray-only Quit is discoverable enough, is a
        // maintainer call. The first-time balloon below is the discoverability
        // hedge until that's settled.
        e.Cancel = true;
        HideToTray();
    }

    protected override void OnStateChanged(EventArgs e)
    {
        // Minimize also parks to the tray, matching "X / minimize leaves the dev
        // server warm" (ADR 0005 / SKILL.md core principle 3).
        if (WindowState == WindowState.Minimized) HideToTray();
        base.OnStateChanged(e);
    }

    private void HideToTray()
    {
        Hide();
        if (!_trayHintShown && _tray is not null)
        {
            _trayHintShown = true;
            _tray.BalloonTipTitle = _config.Title;
            _tray.BalloonTipText =
                "Still running here — the dev server stays warm. Right-click → Quit to stop it.";
            _tray.ShowBalloonTip(4000);
        }
    }

    public void ReShow()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
        Topmost = true;   // nudge to the foreground...
        Topmost = false;  // ...without actually pinning it there
        Focus();
    }

    private void QuitApp()
    {
        _quitting = true;
        // Dispose the job FIRST: KILL_ON_JOB_CLOSE reaps the dev-server tree and
        // frees the port before the process goes away.
        _server?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        Application.Current.Shutdown();
    }

    // ---- Tray icon ---------------------------------------------------------

    private void SetupTray()
    {
        _tray = new Forms.NotifyIcon
        {
            Text = _config.Title,
            Icon = LoadTrayIcon(),
            Visible = true,
        };

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add($"Show {_config.Title}", null, (_, _) => ReShow());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => QuitApp());
        _tray.ContextMenuStrip = menu;

        _tray.DoubleClick += (_, _) => ReShow();
    }

    private Drawing.Icon LoadTrayIcon()
    {
        if (!string.IsNullOrWhiteSpace(_config.IconPath) && File.Exists(_config.IconPath))
        {
            try { return new Drawing.Icon(_config.IconPath); }
            catch { /* fall through to the system default */ }
        }
        return Drawing.SystemIcons.Application;
    }

    private void ApplyIcon()
    {
        if (string.IsNullOrWhiteSpace(_config.IconPath) || !File.Exists(_config.IconPath)) return;
        try
        {
            Icon = BitmapFrame.Create(
                new Uri(_config.IconPath), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        }
        catch
        {
            // Keep the default window icon if the .ico can't be decoded.
        }
    }
}
