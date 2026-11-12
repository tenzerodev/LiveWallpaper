import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Wallpaper window (one per screen, sits at desktop level, below the icons)

final class WallpaperWindow: NSWindow {
    private let playerLayer = AVPlayerLayer()

    init(for screen: NSScreen, player: AVPlayer) {
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: true)

        // Desktop level: above the system wallpaper, below desktop icons and all apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        contentView = view
    }
}

// MARK: - One looping player per video file (screens showing the same video share it)

final class ScreenPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func load(_ newURL: URL?) {
        guard newURL != url else { return }   // don't restart if unchanged
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        url = newURL
        if let newURL {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: newURL))
        }
    }
}

// MARK: - Screen identity (stable across restarts / replugging)

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Built from the monitor's vendor / model / serial so the same monitor
    /// keeps its video even if macOS gives it a different display number.
    var stableID: String {
        let id = displayID
        let serial = CGDisplaySerialNumber(id)
        let tail = serial != 0 ? "\(serial)" : "u\(CGDisplayUnitNumber(id))"
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(tail)"
    }

    /// Every connected screen with an ID that's unique even when two identical monitors report the same serial number.
    static var screensWithIDs: [(screen: NSScreen, id: String)] {
        var seen = Set<String>()
        return screens.map { screen in
            var id = screen.stableID
            if seen.contains(id) { id += "-d\(screen.displayID)" }
            seen.insert(id)
            return (screen, id)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    private var windows: [String: WallpaperWindow] = [:]
    private var players: [String: ScreenPlayer] = [:]   // by video path

    private var userPaused = false
    // Kept apart so waking the computer doesn't start the video behind the lock screen.
    private var locked = false
    private var displaysAsleep = false
    private var systemAsleep = false

    private let defaultVideoKey = "videoPath"        // video used by every screen without its own
    private let screenVideosKey = "screenVideos"     // [screenID: path] per-screen choices

    // MARK: Saved settings

    private var defaultVideo: URL? {
        get { savedURL(UserDefaults.standard.string(forKey: defaultVideoKey)) }
        set { UserDefaults.standard.set(newValue?.path, forKey: defaultVideoKey) }
    }

    private var screenVideos: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: screenVideosKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: screenVideosKey) }
    }

    private func savedURL(_ path: String?) -> URL? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func video(for screenID: String) -> URL? {
        savedURL(screenVideos[screenID]) ?? defaultVideo
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        rebuildWindows()

        if defaultVideo == nil && screenVideos.isEmpty {
            chooseVideoForAll()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Save battery: pause when displays sleep, the computer sleeps or the screen locks.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displaysDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displaysDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    // MARK: Menu bar (rebuilt each time it opens, so it always lists current screens)

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                                           accessibilityDescription: "Live Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let screens = NSScreen.screensWithIDs
        let allTitle = screens.count > 1 ? "Choose Video for All Screens…" : "Choose Video…"
        add(to: menu, allTitle, #selector(chooseVideoForAll), key: "o")

        if screens.count > 1 {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Per Screen", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (index, (screen, id)) in screens.enumerated() {
                let current = video(for: id)?.lastPathComponent ?? "no video"
                let custom = screenVideos[id] != nil
                let name = screenName(screen, index: index, in: screens.map(\.screen))

                let item = add(to: menu, "\(name) — \(current)…", #selector(chooseVideoForScreen(_:)))
                item.representedObject = id
                item.state = custom ? .on : .off   // ✓ = has its own video
                item.indentationLevel = 1

                if custom {
                    let reset = add(to: menu, "Use Shared Video on \(name)", #selector(resetScreen(_:)))
                    reset.representedObject = id
                    reset.indentationLevel = 2
                }
            }
        }

        menu.addItem(.separator())
        add(to: menu, userPaused ? "Resume" : "Pause", #selector(togglePause), key: "p")

        menu.addItem(.separator())
        menu.addItem(lockScreenMenu())

        menu.addItem(.separator())
        let login = add(to: menu, "Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        add(to: menu, "Quit Live Wallpaper", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func screenName(_ screen: NSScreen, index: Int, in screens: [NSScreen]) -> String {
        let name = screen.localizedName
        let duplicates = screens.filter { $0.localizedName == name }.count > 1
        return duplicates ? "\(name) (\(index + 1))" : name
    }

    // MARK: Windows & players

    /// One window per screen that has a video. A screen without one keeps its normal wallpaper instead of going black.
    private func rebuildWindows() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()

        var usedVideos = Set<String>()
        for (screen, id) in NSScreen.screensWithIDs {
            guard let url = video(for: id) else { continue }
            usedVideos.insert(url.path)

            let sp = players[url.path] ?? ScreenPlayer()
            players[url.path] = sp
            sp.load(url)

            let w = WallpaperWindow(for: screen, player: sp.player)
            w.orderBack(nil)
            windows[id] = w
        }

        // Stop players no screen shows any more.
        for path in players.keys where !usedVideos.contains(path) {
            players[path]?.load(nil)
            players[path] = nil
        }
        updatePlayback()
    }

    private func reloadAllPlayers() { rebuildWindows() }

    @objc private func screensChanged() { rebuildWindows() }

    // MARK: Choosing videos

    private func pickVideo(title: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Sets one video for every screen and clears per-screen choices.
    @objc private func chooseVideoForAll() {
        guard let url = pickVideo(title: "Choose a video for all screens") else { return }
        defaultVideo = url
        screenVideos = [:]
        reloadAllPlayers()
    }

    @objc private func chooseVideoForScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let name = NSScreen.screensWithIDs.first { $0.id == id }?.screen.localizedName ?? "this screen"
        guard let url = pickVideo(title: "Choose a video for \(name)") else { return }
        var map = screenVideos
        map[id] = url.path
        screenVideos = map
        reloadAllPlayers()
    }

    @objc private func resetScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var map = screenVideos
        map[id] = nil
        screenVideos = map
        reloadAllPlayers()
    }

    // MARK: Playback

    private func updatePlayback() {
        let paused = userPaused || locked || displaysAsleep || systemAsleep
        for sp in players.values {
            if paused { sp.player.pause() } else { sp.player.play() }
        }
    }

    @objc private func togglePause() {
        userPaused.toggle()
        updatePlayback()
    }

    @objc private func screenLocked() { locked = true; updatePlayback() }
    @objc private func screenUnlocked() { locked = false; updatePlayback() }
    @objc private func displaysDidSleep() { displaysAsleep = true; updatePlayback() }
    @objc private func displaysDidWake() { displaysAsleep = false; updatePlayback() }
    @objc private func systemWillSleep() { systemAsleep = true; updatePlayback() }
    @objc private func systemDidWake() { systemAsleep = false; updatePlayback() }

    // MARK: Lock screen

    private var currentVideo: URL? {
        if let main = NSScreen.screensWithIDs.first(where: { $0.screen == NSScreen.main }), let url = video(for: main.id) {
            return url
        }
        return defaultVideo ?? NSScreen.screensWithIDs.lazy.compactMap { self.video(for: $0.id) }.first
    }

    private func lockScreenMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let lock = LockScreenAerial.shared

        func info(_ text: String) {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.isEnabled = false
            sub.addItem(i)
        }

        if !lock.isSupported {
            info("Needs macOS 26 or later")
        } else {
            info(lock.currentVideoName.map { "Showing: \($0)" } ?? "Not set")
            let use = add(to: sub, "Use Current Video on Lock Screen", #selector(useCurrentVideoOnLockScreen))
            use.isEnabled = currentVideo != nil
            add(to: sub, "Choose Video for Lock Screen…", #selector(chooseVideoForLockScreen))
            if lock.currentVideoName != nil {
                sub.addItem(.separator())
                add(to: sub, "Remove from Lock Screen", #selector(removeFromLockScreen))
            }
        }
        item.submenu = sub
        return item
    }

    @objc private func useCurrentVideoOnLockScreen() {
        guard let url = currentVideo else { return }
        setLockScreen(url)
    }

    @objc private func chooseVideoForLockScreen() {
        guard let url = pickVideo(title: "Choose a video for the lock screen") else { return }
        setLockScreen(url)
    }

    private func setLockScreen(_ url: URL) {
        LockScreenAerial.shared.install(video: url) { error in
            let alert = NSAlert()
            if let error {
                alert.alertStyle = .warning
                alert.messageText = "Couldn't put the video on the lock screen"
                alert.informativeText = error.localizedDescription
            } else {
                alert.messageText = "Lock screen updated"
                alert.informativeText = """
                “\(url.lastPathComponent)” will now play on the lock screen and as the screen saver.

                Lock your Mac (Control-Command-Q) to see it. It also appears in System Settings → Wallpaper under “Live Wallpaper”.

                To undo: Lock Screen → Remove from Lock Screen. Your previous wallpaper settings are restored.
                """
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func removeFromLockScreen() {
        LockScreenAerial.shared.remove()
    }

    // MARK: Login item

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "Move LiveWallpaper.app to your Applications folder and try again.\n\n\(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
