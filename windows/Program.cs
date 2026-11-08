using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace LiveWallpaper;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new System.Threading.Mutex(true, "tenzerodev.LiveWallpaper", out bool firstInstance);
        if (!firstInstance) return;

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        _ = new WallpaperController(app);
        app.Run();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings (saved to %APPDATA%\LiveWallpaper\settings.json)
// ─────────────────────────────────────────────────────────────────────────────

sealed class Settings
{
    public string? DefaultVideo { get; set; }
    public Dictionary<string, string> ScreenVideos { get; set; } = new();
    public bool PauseWhenFullscreen { get; set; } = true;

    static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LiveWallpaper");
    static string FilePath => Path.Combine(Folder, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
        catch { return new Settings(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* not fatal */ }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// One borderless video window per monitor, re-parented behind the desktop icons
// ─────────────────────────────────────────────────────────────────────────────

sealed class WallpaperWindow : Window
{
    readonly MediaElement media;
    bool playing;
    public string? VideoPath { get; private set; }

    public WallpaperWindow()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Background = Brushes.Black;
        Left = -32000; Top = -32000; Width = 1; Height = 1;

        media = new MediaElement
        {
            LoadedBehavior = MediaState.Manual,
            UnloadedBehavior = MediaState.Manual,
            Stretch = Stretch.UniformToFill,
            IsMuted = true,
            Volume = 0,
        };
        media.MediaEnded += (_, _) => { media.Position = TimeSpan.Zero; media.Play(); };   // loop
        Content = media;
    }

    public void AttachTo(IntPtr host, Drawing.Rectangle screenBounds)
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        int ex = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
        Native.SetParent(hwnd, host);
        Show();

        // Child coordinates are relative to the host window.
        Native.GetWindowRect(host, out var hostRect);
        Native.SetWindowPos(hwnd, IntPtr.Zero,
            screenBounds.X - hostRect.Left, screenBounds.Y - hostRect.Top,
            screenBounds.Width, screenBounds.Height,
            Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    public void Load(string? path)
    {
        if (string.Equals(path, VideoPath, StringComparison.OrdinalIgnoreCase)) return;
        VideoPath = path;
        media.Stop();
        media.Source = path is null ? null : new Uri(path);
        if (path is null) return;
        media.Play();
        if (!playing) media.Pause();
    }

    public void SetPlaying(bool play)
    {
        playing = play;
        if (VideoPath is null) return;
        if (play) media.Play(); else media.Pause();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// App logic + tray icon
// ─────────────────────────────────────────────────────────────────────────────

sealed class WallpaperController
{
    readonly Application app;
    readonly Settings settings = Settings.Load();
    readonly Dictionary<string, WallpaperWindow> windows = new();
    readonly Forms.NotifyIcon tray;
    readonly DispatcherTimer watchdog;
    IntPtr host;

    bool userPaused, sessionPaused, fullscreenPaused;

    public WallpaperController(Application app)
    {
        this.app = app;

        tray = new Forms.NotifyIcon
        {
            Icon = TrayIcon.Make(""),          // Segoe MDL2 "Video" glyph
            Text = "Live Wallpaper",
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip(),
        };
        BuildMenu();
        tray.ContextMenuStrip.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)   // left-click opens the menu too
                typeof(Forms.NotifyIcon).GetMethod("ShowContextMenu",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.Invoke(tray, null);
        };

        Rebuild();

        SystemEvents.DisplaySettingsChanged += (_, _) => OnUi(Rebuild);
        SystemEvents.SessionSwitch += (_, e) => OnUi(() =>
        {
            if (e.Reason == SessionSwitchReason.SessionLock) sessionPaused = true;
            if (e.Reason == SessionSwitchReason.SessionUnlock) sessionPaused = false;
            UpdatePlayback();
        });
        SystemEvents.PowerModeChanged += (_, e) => OnUi(() =>
        {
            if (e.Mode == PowerModes.Suspend) sessionPaused = true;
            if (e.Mode == PowerModes.Resume) { sessionPaused = false; Rebuild(); }
            UpdatePlayback();
        });

        // Every 2 s: re-attach if Explorer restarted, and pause behind full-screen apps/games.
        watchdog = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        watchdog.Tick += (_, _) =>
        {
            if (host == IntPtr.Zero || !Native.IsWindow(host)) Rebuild();
            bool fs = settings.PauseWhenFullscreen && Native.ForegroundIsFullscreen();
            if (fs != fullscreenPaused) { fullscreenPaused = fs; UpdatePlayback(); }
        };
        watchdog.Start();

        if (settings.DefaultVideo is null && settings.ScreenVideos.Count == 0)
            app.Dispatcher.BeginInvoke(ChooseForAll, DispatcherPriority.ApplicationIdle);
    }

    void OnUi(Action a) => app.Dispatcher.BeginInvoke(a);

    // ── Videos ───────────────────────────────────────────────────────────────

    static string? Existing(string? path) => path is not null && File.Exists(path) ? path : null;

    string? VideoFor(string screenId) =>
        Existing(settings.ScreenVideos.GetValueOrDefault(screenId)) ?? Existing(settings.DefaultVideo);

    void Rebuild()
    {
        foreach (var w in windows.Values) w.Close();
        windows.Clear();

        host = DesktopHost.Find();
        if (host == IntPtr.Zero) return;

        foreach (var screen in Forms.Screen.AllScreens)
        {
            var w = new WallpaperWindow();
            w.AttachTo(host, screen.Bounds);
            w.Load(VideoFor(screen.DeviceName));
            windows[screen.DeviceName] = w;
        }
        UpdatePlayback();
    }

    void ReloadAll()
    {
        foreach (var (id, w) in windows) w.Load(VideoFor(id));
        UpdatePlayback();
    }

    void UpdatePlayback()
    {
        bool play = !(userPaused || sessionPaused || fullscreenPaused);
        foreach (var w in windows.Values) w.SetPlaying(play);
    }

    static string? PickVideo(string title)
    {
        using var dlg = new Forms.OpenFileDialog
        {
            Title = title,
            Filter = "Videos|*.mp4;*.m4v;*.mov;*.wmv;*.avi|All files|*.*",
            CheckFileExists = true,
        };
        return dlg.ShowDialog() == Forms.DialogResult.OK ? dlg.FileName : null;
    }

    void ChooseForAll()
    {
        var path = PickVideo("Choose a video for all screens");
        if (path is null) return;
        settings.DefaultVideo = path;
        settings.ScreenVideos.Clear();
        settings.Save();
        ReloadAll();
    }

    void ChooseForScreen(string id, string name)
    {
        var path = PickVideo($"Choose a video for {name}");
        if (path is null) return;
        settings.ScreenVideos[id] = path;
        settings.Save();
        ReloadAll();
    }

    void ResetScreen(string id)
    {
        settings.ScreenVideos.Remove(id);
        settings.Save();
        ReloadAll();
    }

    // ── Tray menu (rebuilt every time it opens) ──────────────────────────────

    void BuildMenu()
    {
        var menu = tray.ContextMenuStrip!;
        menu.Items.Clear();

        var screens = Forms.Screen.AllScreens;
        Add(menu, screens.Length > 1 ? "Choose Video for All Screens…" : "Choose Video…", ChooseForAll);

        if (host == IntPtr.Zero)
            menu.Items.Add(new Forms.ToolStripMenuItem("⚠ Couldn't find the desktop — try restarting the app") { Enabled = false });

        if (screens.Length > 1)
        {
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add(new Forms.ToolStripMenuItem("Per Screen") { Enabled = false });
            for (int i = 0; i < screens.Length; i++)
            {
                var s = screens[i];
                string id = s.DeviceName;
                string name = $"Display {i + 1}{(s.Primary ? " (main)" : "")} — {s.Bounds.Width}×{s.Bounds.Height}";
                string current = Path.GetFileName(VideoFor(id)) is { Length: > 0 } f ? f : "no video";
                bool custom = settings.ScreenVideos.ContainsKey(id);

                var item = Add(menu, $"    {name}: {current}…", () => ChooseForScreen(id, name));
                item.Checked = custom;
                if (custom) Add(menu, $"        Use shared video on Display {i + 1}", () => ResetScreen(id));
            }
        }

        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, userPaused ? "Resume" : "Pause", () => { userPaused = !userPaused; UpdatePlayback(); });
        Add(menu, "Pause when an app or game is full screen", () =>
        {
            settings.PauseWhenFullscreen = !settings.PauseWhenFullscreen;
            settings.Save();
        }).Checked = settings.PauseWhenFullscreen;

        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Start with Windows", () => Startup.Enabled = !Startup.Enabled).Checked = Startup.Enabled;

        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Quit Live Wallpaper", Quit);
    }

    static Forms.ToolStripMenuItem Add(Forms.ContextMenuStrip menu, string text, Action onClick)
    {
        var item = new Forms.ToolStripMenuItem(text);
        item.Click += (_, _) => onClick();
        menu.Items.Add(item);
        return item;
    }

    void Quit()
    {
        watchdog.Stop();
        foreach (var w in windows.Values) w.Close();
        windows.Clear();
        tray.Visible = false;
        tray.Dispose();
        Native.RefreshDesktopWallpaper();   // repaint the normal wallpaper
        app.Shutdown();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Finding the window that sits behind the desktop icons
// ─────────────────────────────────────────────────────────────────────────────

static class DesktopHost
{
    public static IntPtr Find()
    {
        IntPtr progman = Native.FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return IntPtr.Zero;

        // Ask Explorer to create the WorkerW layer between wallpaper and icons.
        Native.SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, Native.SMTO_NORMAL, 1000, out _);
        Native.SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), Native.SMTO_NORMAL, 1000, out _);

        // Windows 11 24H2+: the WorkerW is a child of Progman.
        IntPtr child = Native.FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (child != IntPtr.Zero) return child;

        // Windows 10 / older Windows 11: the WorkerW right after the one holding the icons.
        IntPtr worker = IntPtr.Zero;
        Native.EnumWindows((top, _) =>
        {
            if (Native.FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                worker = Native.FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
            return true;
        }, IntPtr.Zero);

        return worker != IntPtr.Zero ? worker : progman;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Start with Windows (HKCU Run key)
// ─────────────────────────────────────────────────────────────────────────────

static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "LiveWallpaper";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue(Name, false);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tray icon drawn at runtime from a Windows symbol font glyph
// ─────────────────────────────────────────────────────────────────────────────

static class TrayIcon
{
    public static Drawing.Icon Make(string glyph)
    {
        using var bmp = new Drawing.Bitmap(32, 32);
        using (var g = Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var bg = new Drawing.SolidBrush(Drawing.Color.FromArgb(255, 37, 99, 235));
            g.FillEllipse(bg, 0, 0, 31, 31);
            using var font = new Drawing.Font("Segoe MDL2 Assets", 17, Drawing.GraphicsUnit.Pixel);
            var size = g.MeasureString(glyph, font);
            g.DrawString(glyph, font, Drawing.Brushes.White, (32 - size.Width) / 2 + 1, (32 - size.Height) / 2 + 1);
        }
        return Drawing.Icon.FromHandle(bmp.GetHicon());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Win32
// ─────────────────────────────────────────────────────────────────────────────

static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x80;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public const uint SMTO_NORMAL = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string? cls, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? cls, string? title);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SystemParametersInfo(uint action, uint param, StringBuilder? value, uint winIni);

    public static bool ForegroundIsFullscreen()
    {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        var cls = new StringBuilder(64);
        GetClassName(fg, cls, cls.Capacity);
        if (cls.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
        if (!GetWindowRect(fg, out var r)) return false;
        var s = Forms.Screen.FromHandle(fg).Bounds;
        return r.Left <= s.Left && r.Top <= s.Top && r.Right >= s.Right && r.Bottom >= s.Bottom;
    }

    public static void RefreshDesktopWallpaper()
    {
        const uint SPI_GETDESKWALLPAPER = 0x73, SPI_SETDESKWALLPAPER = 0x14, SPIF_SENDCHANGE = 0x2;
        var path = new StringBuilder(520);
        SystemParametersInfo(SPI_GETDESKWALLPAPER, (uint)path.Capacity, path, 0);
        SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, path, SPIF_SENDCHANGE);
    }
}
