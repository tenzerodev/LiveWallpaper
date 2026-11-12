# Live Wallpaper for macOS

A tiny menu-bar app that plays any video as a looping, animated desktop wallpaper.

## Features
- Plays any `.mp4` / `.mov` / `.m4v` behind your desktop icons
- Covers every connected display, and adapts when you plug/unplug monitors
- Different video per monitor (menu → Per Screen), remembered per monitor
- Shows on all Spaces
- Muted, seamless looping (AVPlayerLooper)
- Pauses automatically when the screen sleeps or locks (saves battery)
- Menu bar controls: Choose Video, Pause/Resume, Launch at Login, Quit
- Remembers your last video
- No Dock icon
- **Lock screen (macOS 26+):** menu → Lock Screen puts your video on the lock screen and screen saver too


## Download (Mac)
1. Get **LiveWallpaper-macOS.zip** from the [latest release](https://github.com/tenzerodev/LiveWallpaper/releases/latest).
2. Unzip it and drag **LiveWallpaper.app** into Applications.
3. The first time, double-click it. macOS will say it can't check the app (it isn't notarized by Apple):
   click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   On macOS 14 or earlier, **right-click → Open → Open** also works.
   If macOS says it's damaged or won't open, run: `xattr -cr /Applications/LiveWallpaper.app`

Works on Apple Silicon and Intel Macs, macOS 13 Ventura or later.

## Lock screen (Mac, macOS 26 or later)
Apps can't draw on the macOS lock screen, but macOS plays its own "Aerial" wallpapers there.
**Lock Screen → Use Current Video on Lock Screen** adds your video as an Aerial (it shows up in
System Settings → Wallpaper under "Live Wallpaper"), selects it for every display, and uses it as
the screen saver. No admin password needed.

- Your previous wallpaper settings are backed up; **Lock Screen → Remove from Lock Screen** restores them.
- This uses an undocumented part of macOS, so a future macOS update could break it.
- Not available on Windows: its lock screen only supports still images.
- Approach adapted from [LivePaper](https://github.com/Raunik2/LivePaper) by Raunak Gupta (MIT License).

## Windows
1. Get **LiveWallpaper-Windows.zip** from the [latest release](https://github.com/tenzerodev/LiveWallpaper/releases/latest) and unzip it.
2. Run **LiveWallpaper.exe**. If SmartScreen says "Windows protected your PC", click **More info → Run anyway** (the app isn't code-signed).
3. Pick a video. The tray icon (bottom-right, near the clock) has Choose Video, Per Screen, Pause, and Start with Windows.

- Works on Windows 10 and 11 (64-bit). MP4 (H.264) plays everywhere; HEVC needs Microsoft's HEVC extension.
- Pauses automatically when the PC is locked or a game/app is full screen.
- Source is in [`windows/`](windows) (C# / .NET 8).

## Build from source (Mac)
Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/tenzerodev/LiveWallpaper.git
cd LiveWallpaper && bash build.sh
```

Then drag `LiveWallpaper.app` into **Applications** and open it.
The first time, macOS may block it because it isn't notarized: use **System Settings → Privacy & Security → Open Anyway**.

Quick dev run without bundling: `swift run`

## Tips
- 4K HEVC (`.mov` / H.265) files use the least CPU thanks to hardware decoding.
- Free looping videos: Pexels, Pixabay, Mixkit (search "loop").
- Launch at Login only works once the app is in /Applications.

## License
GPL-3.0 — see [LICENSE](LICENSE).
