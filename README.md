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

## Download
1. Get **LiveWallpaper-macOS.zip** from the [latest release](https://github.com/tenzerodev/LiveWallpaper/releases/latest).
2. Unzip it and drag **LiveWallpaper.app** into Applications.
3. The first time, **right-click → Open → Open** (the app isn't notarized by Apple).
   If macOS says it's damaged or won't open, run: `xattr -cr /Applications/LiveWallpaper.app`

Works on Apple Silicon and Intel Macs, macOS 13 Ventura or later.

## Build from source
Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/tenzerodev/LiveWallpaper.git
cd LiveWallpaper && bash build.sh
```

Then drag `LiveWallpaper.app` into **Applications** and open it.
The first time, right-click → **Open** (it's ad-hoc signed, not notarized).

Quick dev run without bundling: `swift run`

## Tips
- 4K HEVC (`.mov` / H.265) files use the least CPU thanks to hardware decoding.
- Free looping videos: Pexels, Pixabay, Mixkit (search "loop").
- Launch at Login only works once the app is in /Applications.

## License
GPL-3.0 — see [LICENSE](LICENSE).
