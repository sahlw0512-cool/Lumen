import AppKit
import AVFoundation

/// Optional: sets the *system* desktop picture to a full-resolution still of
/// the video, using the public `NSWorkspace.setDesktopImageURL(_:for:options:)`.
///
/// Why: the animated window can't appear in Mission Control's Spaces bar,
/// the lock screen, or during the instant a Space-switch animation reveals the
/// real desktop. Matching the static picture makes those moments seamless.
///
/// The user's original pictures are recorded first and restored when the
/// feature is turned off or the app quits. If the app crashes, the records
/// survive in UserDefaults and are restored on next launch.
///
/// Limitation: macOS applies this to the *current* Space of each display only.
@MainActor
final class StaticWallpaperSync {
    private let defaultsKey = "staticWallpaperSync.originals"
    private let thumbnails: ThumbnailService
    private var originals: [String: String]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(thumbnails: ThumbnailService) {
        self.thumbnails = thumbnails
        originals = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    var hasSavedOriginals: Bool { !originals.isEmpty }

    /// `frameTime` is the frame the user picked for the lock screen and login window.
    func sync(display: DisplayInfo, screen: NSScreen, videoURL: URL, wallpaperID: UUID, scaling: ScalingMode, frameTime: Double = 0) {
        tasks[display.id]?.cancel()
        recordOriginal(display: display, screen: screen)
        let frameKey = Int((frameTime * 100).rounded())
        let posterURL = AppPaths.posters.appendingPathComponent("\(wallpaperID.uuidString)-\(display.pixelWidth)x\(display.pixelHeight)-\(frameKey).jpg")
        if NSWorkspace.shared.desktopImageURL(for: screen) == posterURL { return }
        let maxSize = CGSize(width: display.pixelWidth, height: display.pixelHeight)
        let thumbnails = self.thumbnails
        tasks[display.id] = Task { [weak self] in
            do {
                if !FileManager.default.fileExists(atPath: posterURL.path) {
                    let access = ScopedFileAccess(url: videoURL)
                    let image = try await thumbnails.frame(from: videoURL, atSeconds: frameTime, maximumSize: maxSize, exact: true)
                    withExtendedLifetime(access) {}
                    try ThumbnailService.writeJPEG(image, to: posterURL, quality: 0.92)
                }
                guard !Task.isCancelled else { return }
                try NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: Self.options(for: scaling))
                Self.removeStalePosters(keeping: posterURL, prefix: "\(wallpaperID.uuidString)-\(display.pixelWidth)x\(display.pixelHeight)-")
                Log.info("Static desktop picture synced for \(display.name)", category: "sync")
            } catch {
                Log.warning("Couldn't set static desktop picture: \(error.localizedDescription)", category: "sync")
            }
            self?.tasks[display.id] = nil
        }
    }

    /// Sets the exact frame a display is showing (for the lock screen when the
    /// screen locks). Each capture gets a new file name, since macOS doesn't
    /// reload a picture whose URL hasn't changed.
    func syncFrame(_ frame: FrameSource, display: DisplayInfo, screen: NSScreen, wallpaperID: UUID, scaling: ScalingMode) {
        tasks[display.id]?.cancel()
        recordOriginal(display: display, screen: screen)
        let prefix = "\(wallpaperID.uuidString)-\(display.pixelWidth)x\(display.pixelHeight)-"
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let posterURL = AppPaths.posters.appendingPathComponent("\(prefix)live-\(stamp).jpg")
        let generator = AVAssetImageGenerator(asset: frame.asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = frame.videoComposition
        generator.maximumSize = CGSize(width: display.pixelWidth, height: display.pixelHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        tasks[display.id] = Task { [weak self] in
            do {
                let image = try await generator.image(at: frame.time).image
                try ThumbnailService.writeJPEG(image, to: posterURL, quality: 0.92)
                guard !Task.isCancelled else { return }
                try NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: Self.options(for: scaling))
                Self.removeStalePosters(keeping: posterURL, prefix: prefix)
                Log.info("Lock screen set to the current frame (\(Format.time(frame.time.seconds))) for \(display.name)", category: "sync")
            } catch {
                Log.warning("Couldn't capture the current frame: \(error.localizedDescription)", category: "sync")
            }
            self?.tasks[display.id] = nil
        }
    }

    private func recordOriginal(display: DisplayInfo, screen: NSScreen) {
        if originals[display.id] == nil, let current = NSWorkspace.shared.desktopImageURL(for: screen) {
            originals[display.id] = current.absoluteString
            persist()
        }
    }

    /// Restores every recorded original picture whose display is connected.
    func restoreAll(screens: [NSScreen], displays: [DisplayInfo]) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for display in displays {
            guard let original = originals[display.id], let url = URL(string: original),
                  let screen = screens.first(where: { $0.displayID == display.displayID }) else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                originals[display.id] = nil
            } catch {
                Log.warning("Couldn't restore desktop picture for \(display.name): \(error.localizedDescription)", category: "sync")
            }
        }
        persist()
        if originals.isEmpty { removePosters() }
    }

    /// Earlier frames of the same wallpaper on the same display.
    private static func removeStalePosters(keeping current: URL, prefix: String) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.posters, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.lastPathComponent != current.lastPathComponent {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist() {
        UserDefaults.standard.set(originals, forKey: defaultsKey)
    }

    private func removePosters() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.posters, includingPropertiesForKeys: nil)) ?? []
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private static func options(for scaling: ScalingMode) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch scaling {
        case .fill:
            [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
             .allowClipping: NSNumber(value: true)]
        case .fit:
            [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
             .allowClipping: NSNumber(value: false),
             .fillColor: NSColor.black]
        case .stretch:
            [.imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
             .allowClipping: NSNumber(value: true)]
        }
    }
}
