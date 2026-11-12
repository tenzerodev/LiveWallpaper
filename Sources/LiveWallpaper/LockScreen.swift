import AppKit
import AVFoundation

/// Shows a video on the macOS lock screen by registering it as a native "Aerial" wallpaper.
///
/// Apps can't draw on the lock screen, but macOS itself plays Aerial wallpapers there.
/// On macOS 26+ the list of Aerials lives in the user's Library, so we add our video to it,
/// select it for every display and space, and restart WallpaperAgent. No admin rights needed.
///
/// Approach adapted from LivePaper by Raunak Gupta (MIT License):
/// https://github.com/Raunik2/LivePaper
final class LockScreenAerial {
    static let shared = LockScreenAerial()

    enum Failure: LocalizedError {
        case unsupported, exportFailed(String), writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Showing a video on the lock screen needs macOS 26 or later."
            case .exportFailed(let why): return "Couldn't prepare the video: \(why)"
            case .writeFailed(let why): return "Couldn't update the wallpaper settings: \(why)"
            }
        }
    }

    private let fm = FileManager.default
    private let base = NSString(string: "~/Library/Application Support/com.apple.wallpaper").expandingTildeInPath
    private var videosDir: String { base + "/aerials/videos" }
    private var thumbsDir: String { base + "/aerials/thumbnails" }
    private var entriesPath: String { base + "/aerials/manifest/entries.json" }
    private var storePath: String { base + "/Store/Index.plist" }
    private var backupPath: String { base + "/Store/Index.plist.livewallpaper-backup" }

    // Our own section in System Settings → Wallpaper.
    private let categoryID = "4C575000-0000-4000-8000-000000000001"
    private let subcategoryID = "4C575000-0000-4000-8000-000000000002"
    private let assetIDKey = "lockScreenAssetID"
    private let videoPathKey = "lockScreenVideoPath"

    var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// File name of the video currently on the lock screen, if any.
    var currentVideoName: String? {
        guard UserDefaults.standard.string(forKey: assetIDKey) != nil,
              let path = UserDefaults.standard.string(forKey: videoPathKey) else { return nil }
        return (path as NSString).lastPathComponent
    }

    // MARK: Install

    func install(video: URL, completion: @escaping (Error?) -> Void) {
        guard isSupported else { completion(Failure.unsupported); return }
        let assetID = UserDefaults.standard.string(forKey: assetIDKey) ?? UUID().uuidString
        let dest = URL(fileURLWithPath: videosDir).appendingPathComponent("\(assetID).mov")

        do {
            try fm.createDirectory(atPath: videosDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: thumbsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        } catch {
            completion(Failure.writeFailed(error.localizedDescription)); return
        }

        // Re-wrap as .mov without re-encoding (fast, no quality loss).
        let asset = AVURLAsset(url: video)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(Failure.exportFailed("this video format isn't supported")); return
        }
        export.outputURL = dest
        export.outputFileType = .mov
        export.exportAsynchronously {
            DispatchQueue.main.async {
                guard export.status == .completed else {
                    completion(Failure.exportFailed(export.error?.localizedDescription ?? "unknown error")); return
                }
                do {
                    self.writeThumbnail(asset: asset, assetID: assetID)
                    try self.addToManifest(assetID: assetID, name: video.deletingPathExtension().lastPathComponent)
                    try self.selectInWallpaperStore(assetID: assetID)
                    self.useAerialScreenSaver()
                    UserDefaults.standard.set(assetID, forKey: self.assetIDKey)
                    UserDefaults.standard.set(video.path, forKey: self.videoPathKey)
                    self.restartWallpaperAgent()
                    completion(nil)
                } catch {
                    completion(Failure.writeFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: Remove

    /// Removes our video and puts back the wallpaper settings from before we changed them.
    func remove() {
        if let assetID = UserDefaults.standard.string(forKey: assetIDKey) {
            try? fm.removeItem(atPath: videosDir + "/\(assetID).mov")
            try? fm.removeItem(atPath: thumbsDir + "/\(assetID).png")
        }
        removeFromManifest()
        if fm.fileExists(atPath: backupPath) {
            try? fm.removeItem(atPath: storePath)
            try? fm.moveItem(atPath: backupPath, toPath: storePath)
        }
        UserDefaults.standard.removeObject(forKey: assetIDKey)
        UserDefaults.standard.removeObject(forKey: videoPathKey)
        restartWallpaperAgent()
    }

    // MARK: Aerial manifest

    private func addToManifest(assetID: String, name: String) throws {
        try fm.createDirectory(atPath: (entriesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var entries: [String: Any] = ["version": 1, "categories": [Any](), "assets": [Any]()]
        if let data = fm.contents(atPath: entriesPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = parsed
        }
        let thumb = URL(fileURLWithPath: thumbsDir + "/\(assetID).png").absoluteString
        let file = URL(fileURLWithPath: videosDir + "/\(assetID).mov").absoluteString

        var categories = (entries["categories"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != categoryID }
        categories.append([
            "id": categoryID,
            "localizedNameKey": "Live Wallpaper",
            "localizedDescriptionKey": "Your Live Wallpaper video",
            "preferredOrder": 999,
            "representativeAssetID": assetID,
            "previewImage": thumb,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "Live Wallpaper",
                "localizedDescriptionKey": "Your Live Wallpaper video",
                "preferredOrder": 0,
                "previewImage": thumb,
                "representativeAssetID": assetID,
            ]],
        ])

        var assets = (entries["assets"] as? [[String: Any]] ?? []).filter {
            !(($0["categories"] as? [String])?.contains(categoryID) ?? false)
        }
        assets.append([
            "id": assetID,
            "localizedNameKey": name,
            "accessibilityLabel": name,
            "shotID": "LIVEWALLPAPER_CUSTOM",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": file,
            "previewImage": thumb,
            "pointsOfInterest": ["0": "LIVEWALLPAPER_0"],
        ])

        entries["categories"] = categories
        entries["assets"] = assets
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: entriesPath), options: .atomic)
    }

    private func removeFromManifest() {
        guard let data = fm.contents(atPath: entriesPath),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        entries["categories"] = (entries["categories"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != categoryID }
        entries["assets"] = (entries["assets"] as? [[String: Any]] ?? []).filter {
            !(($0["categories"] as? [String])?.contains(categoryID) ?? false)
        }
        if let out = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: entriesPath), options: .atomic)
        }
    }

    // MARK: Wallpaper selection (all displays + spaces, which is what the lock screen uses)

    private func selectInWallpaperStore(assetID: String) throws {
        try fm.createDirectory(atPath: (storePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Keep the original settings once, so "Remove" can put them back.
        if fm.fileExists(atPath: storePath) && !fm.fileExists(atPath: backupPath) {
            try fm.copyItem(atPath: storePath, toPath: backupPath)
        }

        var store: [String: Any] = [:]
        if let data = fm.contents(atPath: storePath),
           let parsed = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] {
            store = parsed
        }

        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": [
                "Content": ["Choices": [[
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Files": [Any](),
                    "Configuration": config,
                ]]],
                "LastSet": Date(),
                "LastUse": Date(),
            ] as [String: Any],
        ]

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry
        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }
        if var spaces = store["Spaces"] as? [String: Any] {
            for key in spaces.keys {
                guard var space = spaces[key] as? [String: Any] else { continue }
                if space["Default"] != nil { space["Default"] = entry }
                if var ds = space["Displays"] as? [String: Any] {
                    for d in ds.keys { ds[d] = entry }
                    space["Displays"] = ds
                }
                spaces[key] = space
            }
            store["Spaces"] = spaces
        }

        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    // MARK: Helpers

    private func writeThumbnail(asset: AVAsset, assetID: String) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: thumbsDir + "/\(assetID).png"))
    }

    /// Let the screen saver (shown before the lock screen) play the same Aerial.
    private func useAerialScreenSaver() {
        run("/usr/bin/defaults", ["-currentHost", "write", "com.apple.screensaver", "moduleDict", "-dict",
                                  "moduleName", "WallpaperAerialsExtension",
                                  "path", "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex",
                                  "type", "0"])
    }

    private func restartWallpaperAgent() {
        // Clear cached Aerial thumbnails so the new video shows up straight away.
        let cache = NSString(string: "~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.aerials").expandingTildeInPath
        for item in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] where item.hasSuffix(".bmp") {
            try? fm.removeItem(atPath: cache + "/" + item)
        }
        run("/usr/bin/killall", ["WallpaperAgent"])   // launchd starts it again
    }

    private func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
