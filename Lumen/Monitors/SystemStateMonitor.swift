import AppKit
import Observation

/// Observes system lifecycle events that should suspend wallpaper playback.
///
/// Documented sources: NSWorkspace sleep/wake, screens sleep/wake, session
/// active/resign (fast user switching), active Space changes, app activation,
/// and ProcessInfo thermal state.
///
/// Undocumented-but-stable sources (no public alternative exists):
/// the distributed notifications `com.apple.screenIsLocked/Unlocked` and
/// `com.apple.screensaver.didstart/didstop`, plus the `CGSSessionScreenIsLocked`
/// key of `CGSessionCopyCurrentDictionary()` as a cross-check. If Apple ever
/// stops posting these, the fallback is the documented screens-did-sleep and
/// session-resign events, which also pause playback.
@MainActor
@Observable
final class SystemStateMonitor {
    private(set) var isSystemAsleep = false
    private(set) var areScreensAsleep = false
    private(set) var isScreenLocked = false
    private(set) var isScreenSaverRunning = false
    private(set) var isSessionActive = true
    private(set) var isAppHidden = false
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// Any state above changed.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The system or the displays woke; renderers may need recovery.
    @ObservationIgnored var onWake: (() -> Void)?
    /// The screen is about to be covered (lock, screen saver, display or
    /// system sleep). Called before playback pauses.
    @ObservationIgnored var onWillCover: (() -> Void)?
    /// The active Space or frontmost app changed (re-check fullscreen coverage).
    @ObservationIgnored var onWorkspaceChange: (() -> Void)?

    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    var isUnderThermalPressure: Bool {
        thermalState == .serious || thermalState == .critical
    }

    func start() {
        guard tokens.isEmpty else { return }
        isScreenLocked = Self.readLockState() ?? false
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let local = NotificationCenter.default

        observe(workspace, NSWorkspace.willSleepNotification) { monitor in
            monitor.onWillCover?()
            monitor.set(\.isSystemAsleep, true, "System will sleep")
        }
        observe(workspace, NSWorkspace.didWakeNotification) { monitor in
            monitor.set(\.isSystemAsleep, false, "System woke")
            monitor.set(\.areScreensAsleep, false, nil)
            monitor.isScreenLocked = Self.readLockState() ?? monitor.isScreenLocked
            monitor.onWake?()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { monitor in
            monitor.onWillCover?()
            monitor.set(\.areScreensAsleep, true, "Displays slept")
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { monitor in
            monitor.set(\.areScreensAsleep, false, "Displays woke")
            monitor.isScreenLocked = Self.readLockState() ?? monitor.isScreenLocked
            monitor.onWake?()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.set(\.isSessionActive, false, "Session became inactive") }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.set(\.isSessionActive, true, "Session became active") }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.onWorkspaceChange?() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.onWorkspaceChange?() }

        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { monitor in
            monitor.onWillCover?()
            monitor.set(\.isScreenLocked, true, "Screen locked")
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(\.isScreenLocked, false, "Screen unlocked") }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { monitor in
            monitor.onWillCover?()
            monitor.set(\.isScreenSaverRunning, true, "Screen saver started")
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { monitor in
            monitor.set(\.isScreenSaverRunning, false, "Screen saver stopped")
            monitor.isScreenLocked = Self.readLockState() ?? monitor.isScreenLocked
            monitor.onChange?()
        }

        observe(local, NSApplication.didHideNotification) { $0.set(\.isAppHidden, true, nil) }
        observe(local, NSApplication.didUnhideNotification) { $0.set(\.isAppHidden, false, nil) }
        observe(local, ProcessInfo.thermalStateDidChangeNotification) { monitor in
            let state = ProcessInfo.processInfo.thermalState
            guard state != monitor.thermalState else { return }
            monitor.thermalState = state
            Log.info("Thermal state: \(Self.describe(state))", category: "system")
            monitor.onChange?()
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (SystemStateMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    private func set(_ keyPath: ReferenceWritableKeyPath<SystemStateMonitor, Bool>, _ value: Bool, _ message: String?) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        if let message { Log.info(message, category: "system") }
        onChange?()
    }

    /// Public CoreGraphics call; the dictionary key itself is undocumented.
    static func readLockState() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
