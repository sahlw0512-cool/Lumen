import AppKit
import Observation

/// Coordinates the renderer with system state. Every playback decision flows
/// through `refreshPlayback()`, which is called only in response to events
/// (settings, displays, power, sleep, lock, Spaces, occlusion) — never on a timer.
@MainActor
@Observable
final class WallpaperEngine {
    struct DisplayState: Equatable {
        var status: RendererStatus
        var pauseReason: PauseReason?
        var wallpaperID: UUID?
        /// The frame-rate ceiling in effect (nil = the video's own rate).
        var frameRateCap: Double?
    }

    private(set) var displayStates: [String: DisplayState] = [:]
    private(set) var fullscreenDisplayIDs: Set<CGDirectDisplayID> = []
    var isUserPaused = false {
        didSet {
            guard isUserPaused != oldValue else { return }
            Log.info(isUserPaused ? "User paused wallpapers" : "User resumed wallpapers", category: "engine")
            refreshPlayback()
        }
    }

    let power = PowerMonitor()
    let system = SystemStateMonitor()
    let idle = IdleMonitor()

    /// Reported when a display's wallpaper fails permanently (after retries).
    @ObservationIgnored var onPermanentFailure: ((UUID, String) -> Void)?

    private let renderer: any WallpaperRenderer
    @ObservationIgnored private(set) lazy var effects = EffectsCoordinator(renderer: renderer)
    private let fullscreenDetector = FullscreenDetector()
    @ObservationIgnored private var displays: [DisplayInfo] = []
    @ObservationIgnored private var settings = AppSettings()
    @ObservationIgnored private var retryCounts: [String: Int] = [:]
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fullscreenCheck: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private let maxRetries = 3

    var isAnyPlaying: Bool {
        displayStates.values.contains { $0.status == .playing }
    }

    /// Pass `nil` to use the default desktop-window renderer. (The default is
    /// built in the body because default-argument expressions are nonisolated
    /// and can't call the main-actor `DesktopWindowRenderer` initializer.)
    init(renderer: (any WallpaperRenderer)? = nil) {
        self.renderer = renderer ?? DesktopWindowRenderer()
    }

    func start(settings: AppSettings, displays: [DisplayInfo]) {
        guard !started else { return }
        started = true
        self.settings = settings
        renderer.coversDesktopIcons = settings.hideDesktopIcons

        renderer.onStatusChange = { [weak self] key in self?.statusChanged(forDisplay: key) }
        renderer.onVisibilityChange = { [weak self] _ in
            self?.refreshPlayback()
            self?.scheduleFullscreenCheck()
        }
        power.onChange = { [weak self] in self?.refreshPlayback() }
        idle.onChange = { [weak self] in self?.refreshPlayback() }
        system.onChange = { [weak self] in self?.refreshPlayback() }
        system.onWake = { [weak self] in self?.recoverAfterWake() }
        system.onWorkspaceChange = { [weak self] in
            self?.renderer.restack()
            self?.scheduleFullscreenCheck()
        }

        power.start()
        system.start()
        configureIdle()
        updateDisplays(displays)
        scheduleFullscreenCheck()
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        renderer.coversDesktopIcons = newSettings.hideDesktopIcons
        configureIdle()
        scheduleFullscreenCheck()
        refreshPlayback()
    }

    func updateDisplays(_ newDisplays: [DisplayInfo]) {
        displays = newDisplays
        renderer.reconcile(with: newDisplays)
        let keys = Set(newDisplays.map(\.id))
        retryCounts = retryCounts.filter { keys.contains($0.key) }
        scheduleFullscreenCheck()
        refreshPlayback()
    }

    /// Applies the desired content for every connected display. Displays
    /// missing from `requests` are cleared.
    func setContent(_ requests: [String: WallpaperRenderRequest], animated: Bool) {
        let crossfade: TimeInterval = animated && settings.crossfadeTransitions ? 0.8 : 0
        for display in displays {
            let desired = requests[display.id]
            let current = renderer.currentRequest(forDisplay: display.id)
            guard desired != current else { continue }
            if let desired, current == nil || desired.requiresReload(comparedTo: current!) {
                retryCounts[display.id] = 0
                retryTasks[display.id]?.cancel()
            }
            renderer.setContent(desired, forDisplay: display.id, crossfade: crossfade)
        }
        refreshPlayback()
    }

    func reloadAll() {
        for display in displays where renderer.currentRequest(forDisplay: display.id) != nil {
            retryCounts[display.id] = 0
            renderer.reload(display: display.id)
        }
        refreshPlayback()
    }

    func refreshPlayback() {
        var newStates: [String: DisplayState] = [:]
        let rate = Float(settings.playbackRate)
        for display in displays {
            let key = display.id
            let request = renderer.currentRequest(forDisplay: key)
            var reason: PauseReason?
            var cap: Double?
            if request != nil {
                let conditions = PlaybackConditions(
                    userPaused: isUserPaused,
                    systemAsleep: system.isSystemAsleep,
                    sessionActive: system.isSessionActive,
                    screenLocked: system.isScreenLocked,
                    screenSaverRunning: system.isScreenSaverRunning,
                    displayAsleep: system.areScreensAsleep || CGDisplayIsAsleep(display.displayID) != 0,
                    thermalPressure: system.isUnderThermalPressure,
                    lowPowerMode: power.isLowPowerMode,
                    onBattery: power.isOnBattery,
                    userIdle: idle.isIdle,
                    appHidden: system.isAppHidden,
                    fullscreenOnDisplay: fullscreenDisplayIDs.contains(display.displayID),
                    surfaceVisible: renderer.isSurfaceVisible(forDisplay: key)
                )
                reason = PlaybackPolicy.pauseReason(for: conditions, settings: settings)
                cap = PlaybackPolicy.frameRateCap(for: conditions, settings: settings)
                renderer.setPlaying(reason == nil, rate: rate, frameRateCap: cap, forDisplay: key)
            }
            newStates[key] = DisplayState(status: renderer.status(forDisplay: key), pauseReason: reason,
                                          wallpaperID: request?.wallpaperID, frameRateCap: reason == nil ? cap : nil)
            if request != nil, reason != displayStates[key]?.pauseReason {
                Log.debug("Display \(key): \(reason.map { "paused (\($0.rawValue))" } ?? "playing")", category: "engine")
            }
        }
        if newStates != displayStates {
            displayStates = newStates
        }
        let anyPlaying = newStates.values.contains { $0.wallpaperID != nil && $0.pauseReason == nil }
        // The clock keeps time on a paused wallpaper, but not while nobody can see it.
        let hiddenReasons: Set<PauseReason> = [.systemAsleep, .sessionInactive, .screenLocked, .screenSaver, .displayAsleep]
        let anyShowing = newStates.values.contains { state in
            state.wallpaperID != nil && !(state.pauseReason.map(hiddenReasons.contains) ?? false)
        }
        effects.update(effects: settings.effects, active: anyPlaying, showing: anyShowing)
    }

    func currentRequest(forDisplay key: String) -> WallpaperRenderRequest? {
        renderer.currentRequest(forDisplay: key)
    }

    func currentFrame(forDisplay key: String) -> FrameSource? {
        renderer.currentFrame(forDisplay: key)
    }

    func shutdown() {
        effects.stop()
        fullscreenCheck?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        renderer.tearDownAll()
        power.stop()
        system.stop()
        idle.stop()
        displayStates = [:]
        Log.info("Engine shut down; all surfaces released", category: "engine")
    }

    // MARK: - Private

    /// Idle detection runs when either idle option (pause or lower frame rate) is on.
    private func configureIdle() {
        idle.configure(enabled: settings.pauseWhenIdle || settings.lowerFrameRateWhenIdle,
                       threshold: TimeInterval(settings.idleMinutes * 60))
    }

    private func statusChanged(forDisplay key: String) {
        let status = renderer.status(forDisplay: key)
        var state = displayStates[key] ?? DisplayState(status: status, pauseReason: nil, wallpaperID: nil)
        state.status = status
        state.wallpaperID = renderer.currentRequest(forDisplay: key)?.wallpaperID
        if displayStates[key] != state { displayStates[key] = state }
        switch status {
        case .playing:
            retryCounts[key] = 0
        case .failed(let message):
            scheduleRetry(forDisplay: key, message: message)
        default:
            break
        }
    }

    /// Transient decoder failures (e.g. after wake, GPU switch) usually succeed
    /// on a fresh pipeline. Back off and give up after a few attempts.
    private func scheduleRetry(forDisplay key: String, message: String) {
        let attempt = (retryCounts[key] ?? 0) + 1
        retryCounts[key] = attempt
        guard attempt <= maxRetries else {
            if let id = renderer.currentRequest(forDisplay: key)?.wallpaperID {
                onPermanentFailure?(id, message)
            }
            return
        }
        retryTasks[key]?.cancel()
        retryTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            guard !Task.isCancelled, let self else { return }
            self.renderer.reload(display: key)
            self.refreshPlayback()
        }
    }

    private func recoverAfterWake() {
        for display in displays {
            if case .failed = renderer.status(forDisplay: display.id) {
                retryCounts[display.id] = 0
                renderer.reload(display: display.id)
            }
        }
        scheduleFullscreenCheck()
        refreshPlayback()
    }

    /// Space switches animate for ~0.3 s; read the window list once afterwards.
    private func scheduleFullscreenCheck() {
        fullscreenCheck?.cancel()
        guard settings.pauseWhenFullscreen else {
            if !fullscreenDisplayIDs.isEmpty {
                fullscreenDisplayIDs = []
                refreshPlayback()
            }
            return
        }
        fullscreenCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let covered = self.fullscreenDetector.coveredDisplays(among: self.displays)
            if covered != self.fullscreenDisplayIDs {
                self.fullscreenDisplayIDs = covered
                Log.debug("Fullscreen coverage changed: \(covered.count) display(s)", category: "engine")
                self.refreshPlayback()
            }
        }
    }
}
