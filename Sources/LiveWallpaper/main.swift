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

// MARK: - One looping player per screen

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
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    private var windows: [String: WallpaperWindow] = [:]
    private var players: [String: ScreenPlayer] = [:]

    private var userPaused = false
    private var systemPaused = false

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

        // Save battery: pause when displays sleep or the screen locks.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemPause),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemResume),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemPause),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemResume),
                       name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(systemPause),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(systemResume),
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

        let screens = NSScreen.screens
        let allTitle = screens.count > 1 ? "Choose Video for All Screens…" : "Choose Video…"
        add(to: menu, allTitle, #selector(chooseVideoForAll), key: "o")

        if screens.count > 1 {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Per Screen", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (index, screen) in screens.enumerated() {
                let id = screen.stableID
                let current = video(for: id)?.lastPathComponent ?? "no video"
                let custom = screenVideos[id] != nil
                let name = screenName(screen, index: index, in: screens)

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

    private func rebuildWindows() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()

        var activeIDs = Set<String>()
        for screen in NSScreen.screens {
            let id = screen.stableID
            activeIDs.insert(id)

            let sp = players[id] ?? ScreenPlayer()
            players[id] = sp
            sp.load(video(for: id))

            let w = WallpaperWindow(for: screen, player: sp.player)
            w.orderBack(nil)
            windows[id] = w
        }

        // Drop players for monitors that were unplugged.
        for id in players.keys where !activeIDs.contains(id) {
            players[id]?.load(nil)
            players[id] = nil
        }
        updatePlayback()
    }

    private func reloadAllPlayers() {
        for (id, sp) in players { sp.load(video(for: id)) }
        updatePlayback()
    }

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
        let name = NSScreen.screens.first { $0.stableID == id }?.localizedName ?? "this screen"
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
        let paused = userPaused || systemPaused
        for sp in players.values {
            if paused { sp.player.pause() } else { sp.player.play() }
        }
    }

    @objc private func togglePause() {
        userPaused.toggle()
        updatePlayback()
    }

    @objc private func systemPause() {
        systemPaused = true
        updatePlayback()
    }

    @objc private func systemResume() {
        systemPaused = false
        updatePlayback()
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
