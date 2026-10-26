import AppKit
import Observation

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Tracks connected displays. Driven entirely by
/// `NSApplication.didChangeScreenParametersNotification`, which AppKit posts for
/// connect/disconnect, resolution, scaling, rotation, arrangement, and primary
/// display changes. No polling.
@MainActor
@Observable
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []

    @ObservationIgnored var onChange: (([DisplayInfo]) -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    init() {
        displays = Self.snapshot()
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pendingRefresh?.cancel()
    }

    func display(withKey key: String) -> DisplayInfo? {
        displays.first { $0.id == key }
    }

    func screen(for display: DisplayInfo) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == display.displayID }
    }

    /// Reconfiguration arrives as a burst of notifications; coalesce them so the
    /// renderer reacts once, after the configuration has settled.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let latest = Self.snapshot()
        guard latest != displays else { return }
        displays = latest
        Log.info("Display configuration changed: \(latest.map { "\($0.name) \($0.pixelsLabel)" }.joined(separator: ", "))", category: "display")
        onChange?(latest)
    }

    static func snapshot() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.displayID else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = Double(screen.backingScaleFactor)
            let pixelWidth = mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            let pixelHeight = mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            let refresh = mode?.refreshRate ?? 0
            return DisplayInfo(
                id: stableKey(for: id),
                displayID: id,
                name: screen.localizedName,
                frame: screen.frame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                backingScale: scale,
                refreshRate: refresh > 0 ? refresh : nil,
                rotation: CGDisplayRotation(id),
                isMain: id == mainID,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                supportsEDR: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
            )
        }
    }

    /// ColorSync's display UUID is stable across reconnects and reboots.
    static func stableKey(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
}
