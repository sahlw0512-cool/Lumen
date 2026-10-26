import AppKit
import AVFoundation

/// What's needed to render the exact frame a display is showing.
struct FrameSource: @unchecked Sendable {
    let asset: AVAsset
    /// Applied so trimmed and crossfaded loops render as they play.
    let videoComposition: AVVideoComposition?
    let time: CMTime
}

enum RendererStatus: Equatable, Sendable {
    case empty
    case loading
    case playing
    case paused
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .empty: "No wallpaper"
        case .loading: "Loading"
        case .playing: "Playing"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }
}

/// Everything a renderer needs to show one wallpaper on one display.
struct WallpaperRenderRequest: Equatable, Sendable {
    let wallpaperID: UUID
    let url: URL
    var layout: SurfaceLayout
    var loopMode: LoopMode
    var muted: Bool
    var volume: Float
    /// Audio played alongside the video, in order. Empty except on the main display.
    var soundtracks: [URL] = []
    /// Displays sharing a sync group show one spanned video and are kept
    /// frame-aligned with each other.
    var syncGroup: UUID?
    /// Draws the clock overlay on this display (when the clock is enabled).
    var showsClock = false
    var loop = LoopSettings()
    /// This wallpaper's own picture adjustments (nil = the global effects).
    var adjustments: WallpaperEffects?

    var scaling: ScalingMode { layout.scaling }

    /// Changing these requires a new decoding pipeline; anything else is applied in place.
    func requiresReload(comparedTo other: WallpaperRenderRequest) -> Bool {
        wallpaperID != other.wallpaperID || url != other.url || loopMode != other.loopMode || loop != other.loop
    }
}

/// The desktop-integration backend. The engine and UI only talk to this
/// protocol, so the window-based backend can be replaced (for example by a
/// future Apple API) without touching anything else.
@MainActor
protocol WallpaperRenderer: AnyObject {
    /// Called with a display key whenever that display's status changes.
    var onStatusChange: ((String) -> Void)? { get set }
    /// Called when a surface becomes visible/hidden (occlusion, reveal).
    var onVisibilityChange: ((String) -> Void)? { get set }
    /// When true, wallpaper surfaces sit above (and so hide) the desktop icons.
    var coversDesktopIcons: Bool { get set }

    func reconcile(with displays: [DisplayInfo])
    func setContent(_ request: WallpaperRenderRequest?, forDisplay key: String, crossfade: TimeInterval)
    /// `frameRateCap` nil means the video's own frame rate.
    func setPlaying(_ playing: Bool, rate: Float, frameRateCap: Double?, forDisplay key: String)
    func setEffects(_ effects: SurfaceEffects)
    func setClock(time: String, date: String)
    /// Pointer location in global AppKit coordinates (nil recenters parallax).
    func setPointer(_ location: CGPoint?)
    /// Smoothed input level in 0...1 for audio-reactive effects.
    func setAudioLevel(_ level: Double)
    func reload(display key: String)
    func status(forDisplay key: String) -> RendererStatus
    func isSurfaceVisible(forDisplay key: String) -> Bool
    func currentRequest(forDisplay key: String) -> WallpaperRenderRequest?
    /// The frame on screen right now, or nil when nothing is loaded.
    func currentFrame(forDisplay key: String) -> FrameSource?
    func restack()
    func tearDownAll()
}

/// Window-per-display backend built on public AppKit/AVFoundation API.
@MainActor
final class DesktopWindowRenderer: WallpaperRenderer {
    var onStatusChange: ((String) -> Void)?
    var onVisibilityChange: ((String) -> Void)?
    var coversDesktopIcons = false {
        didSet {
            guard coversDesktopIcons != oldValue else { return }
            controllers.values.forEach { $0.coversDesktopIcons = coversDesktopIcons }
        }
    }

    private var controllers: [String: DisplayWallpaperController] = [:]
    private var effects = SurfaceEffects()
    private var clockText: (time: String, date: String) = ("", "")
    private var syncTask: Task<Void, Never>?
    private var syncTimer: Timer?

    func reconcile(with displays: [DisplayInfo]) {
        let liveKeys = Set(displays.map(\.id))
        for (key, controller) in controllers where !liveKeys.contains(key) {
            Log.info("Removing surface for disconnected display", category: "renderer")
            controller.tearDown()
            controllers[key] = nil
        }
        for display in displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            if let controller = controllers[display.id] {
                controller.update(display: display, screen: screen)
            } else {
                let controller = DisplayWallpaperController(display: display, screen: screen)
                controller.coversDesktopIcons = coversDesktopIcons
                controller.setEffects(effects)
                controller.setClock(time: clockText.time, date: clockText.date)
                controller.onStatusChange = { [weak self] key in
                    self?.onStatusChange?(key)
                    self?.scheduleSync()
                }
                controller.onVisibilityChange = { [weak self] key in self?.onVisibilityChange?(key) }
                controllers[display.id] = controller
            }
        }
    }

    func setContent(_ request: WallpaperRenderRequest?, forDisplay key: String, crossfade: TimeInterval) {
        guard let controller = controllers[key] else { return }
        if let request {
            controller.load(request, crossfade: crossfade)
        } else {
            controller.clear(animated: crossfade > 0)
        }
        updateSyncTimer()
    }

    func setPlaying(_ playing: Bool, rate: Float, frameRateCap: Double?, forDisplay key: String) {
        guard let controller = controllers[key] else { return }
        let wasPlaying = controller.isPlaying
        controller.setPlaying(playing, rate: rate, frameRateCap: frameRateCap)
        if playing && !wasPlaying { scheduleSync() }
    }

    func setEffects(_ effects: SurfaceEffects) {
        guard effects != self.effects else { return }
        self.effects = effects
        controllers.values.forEach { $0.setEffects(effects) }
    }

    func setClock(time: String, date: String) {
        clockText = (time, date)
        controllers.values.forEach { $0.setClock(time: time, date: date) }
    }

    func setPointer(_ location: CGPoint?) {
        controllers.values.forEach { $0.setPointer(location) }
    }

    func setAudioLevel(_ level: Double) {
        controllers.values.forEach { $0.setAudioLevel(level) }
    }

    func reload(display key: String) {
        controllers[key]?.reload()
    }

    func status(forDisplay key: String) -> RendererStatus {
        controllers[key]?.status ?? .empty
    }

    func isSurfaceVisible(forDisplay key: String) -> Bool {
        controllers[key]?.isSurfaceVisible ?? false
    }

    func currentRequest(forDisplay key: String) -> WallpaperRenderRequest? {
        controllers[key]?.request
    }

    func currentFrame(forDisplay key: String) -> FrameSource? {
        controllers[key]?.currentFrame
    }

    func restack() {
        controllers.values.forEach { $0.restack() }
    }

    func tearDownAll() {
        syncTask?.cancel()
        syncTimer?.invalidate()
        syncTimer = nil
        controllers.values.forEach { $0.tearDown() }
        controllers.removeAll()
    }

    // MARK: Span sync

    /// Spanned displays each decode the same file; after loading, resuming, and
    /// periodically, followers are snapped to the leader so seams never tear.
    private func scheduleSync() {
        guard controllers.values.contains(where: { $0.request?.syncGroup != nil }) else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.alignSyncGroups()
        }
    }

    private func alignSyncGroups() {
        let spanned = controllers.values.filter { $0.request?.syncGroup != nil && $0.isPlaying }
        let grouped = Dictionary(grouping: spanned) { $0.request?.syncGroup }
        for members in grouped.values where members.count > 1 {
            let ordered = members.sorted { $0.displayKey < $1.displayKey }
            guard let leaderTime = ordered[0].playbackTime else { continue }
            for follower in ordered.dropFirst() {
                follower.align(to: leaderTime)
            }
        }
    }

    private func updateSyncTimer() {
        let needsTimer = controllers.values.contains { $0.request?.syncGroup != nil }
        if needsTimer, syncTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignSyncGroups() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            syncTimer = timer
        } else if !needsTimer {
            syncTimer?.invalidate()
            syncTimer = nil
        }
        scheduleSync()
    }
}

/// Owns the window, surface, player, and file access for one display.
@MainActor
final class DisplayWallpaperController {
    let displayKey: String
    private(set) var displayID: CGDirectDisplayID
    private(set) var request: WallpaperRenderRequest?
    private(set) var status: RendererStatus = .empty

    var onStatusChange: ((String) -> Void)?
    var onVisibilityChange: ((String) -> Void)?

    private let window: DesktopWallpaperWindow
    private let surface: VideoSurfaceView
    private var player: LoopingVideoPlayer?
    private var soundtrackPlayer: SoundtrackPlayer?
    private var fileAccess: ScopedFileAccess?
    private var retiring: [(LoopingVideoPlayer, ScopedFileAccess?)] = []
    private var occlusionObserver: NSObjectProtocol?
    private var wantsPlaying = false
    private var rate: Float = 1
    private var frameRateCap: Double?
    private var globalEffects = SurfaceEffects()
    private var isTornDown = false

    var isPlaying: Bool { wantsPlaying && player != nil && status == .playing }

    var playbackTime: CMTime? { player?.player.currentTime() }

    var currentFrame: FrameSource? {
        guard let item = player?.player.currentItem else { return nil }
        return FrameSource(asset: item.asset, videoComposition: item.videoComposition, time: item.currentTime())
    }

    init(display: DisplayInfo, screen: NSScreen) {
        displayKey = display.id
        displayID = display.displayID
        window = DesktopWallpaperWindow(screen: screen)
        surface = VideoSurfaceView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = surface
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onVisibilityChange?(self.displayKey)
            }
        }
    }

    /// While loading or fading in, the surface counts as visible so occlusion
    /// checks don't pause a pipeline before its window is fully opaque (the
    /// window server reports a transparent window as occluded).
    var isSurfaceVisible: Bool {
        guard window.isVisible else { return false }
        if status == .loading || isFadingIn { return true }
        return window.occlusionState.contains(.visible)
    }

    private var isFadingIn = false

    var coversDesktopIcons: Bool {
        get { window.coversDesktopIcons }
        set { window.coversDesktopIcons = newValue }
    }

    func update(display: DisplayInfo, screen: NSScreen) {
        displayID = display.displayID
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
    }

    func load(_ newRequest: WallpaperRenderRequest, crossfade: TimeInterval) {
        guard !isTornDown else { return }
        if let current = request, !newRequest.requiresReload(comparedTo: current), player != nil, !status.isFailure {
            applyInPlace(newRequest)
            return
        }

        let access = ScopedFileAccess(url: newRequest.url)
        let newPlayer = LoopingVideoPlayer(url: newRequest.url, loopMode: newRequest.loopMode, loop: newRequest.loop)
        newPlayer.setAudio(muted: newRequest.muted, volume: newRequest.volume)
        newPlayer.onFailure = { [weak self, weak newPlayer] message in
            guard let self, let newPlayer, newPlayer === self.player else { return }
            self.setStatus(.failed(message))
        }

        newPlayer.setFrameRateCap(frameRateCap)
        if let player { retiring.append((player, fileAccess)) }
        player = newPlayer
        fileAccess = access
        request = newRequest
        surface.layout = newRequest.layout
        surface.showsClock = newRequest.showsClock
        applySurfaceEffects()
        updateSoundtrack(for: newRequest)
        setStatus(.loading)

        let windowWasVisible = window.isVisible && window.alphaValue > 0.99
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        surface.present(
            player: newPlayer.player,
            crossfade: windowWasVisible ? crossfade : 0,
            onReveal: { [weak self, weak newPlayer] in
                guard let self, let newPlayer, newPlayer === self.player else { return }
                self.didReveal(fadeInWindow: !windowWasVisible, duration: max(crossfade, 0.35))
            },
            onTransitionComplete: { [weak self] in
                self?.releaseRetiredPlayers()
            }
        )
        // Pre-roll: the first frame decodes even while paused.
        applyPlaybackState()
    }

    func reload() {
        guard let request else { return }
        Log.info("Reloading surface after failure", category: "renderer")
        self.request = nil
        load(request, crossfade: 0)
    }

    func clear(animated: Bool) {
        guard request != nil || player != nil else { return }
        request = nil
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.request == nil else { return }
            self.window.orderOut(nil)
            self.surface.clear()
            if let player = self.player { self.retiring.append((player, self.fileAccess)) }
            self.player = nil
            self.fileAccess = nil
            self.soundtrackPlayer?.invalidate()
            self.soundtrackPlayer = nil
            self.releaseRetiredPlayers()
        }
        setStatus(.empty)
        if animated && window.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                self.window.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        } else {
            finish()
        }
    }

    func setPlaying(_ playing: Bool, rate: Float, frameRateCap: Double?) {
        wantsPlaying = playing
        self.rate = rate
        if frameRateCap != self.frameRateCap {
            self.frameRateCap = frameRateCap
            player?.setFrameRateCap(frameRateCap)
        }
        applyPlaybackState()
    }

    func setEffects(_ effects: SurfaceEffects) {
        globalEffects = effects
        applySurfaceEffects()
    }

    /// Global effects, with this wallpaper's own picture adjustments when it has them.
    private func applySurfaceEffects() {
        var effects = globalEffects
        if let adjustments = request?.adjustments {
            effects.effects = adjustments.adjustments(appliedTo: globalEffects.effects)
        }
        surface.effects = effects
    }

    func setClock(time: String, date: String) {
        surface.setClock(time: time, date: date)
    }

    func setPointer(_ location: CGPoint?) {
        guard let location else {
            surface.setParallax(.zero)
            return
        }
        // A paused or covered display isn't drawing; don't animate it.
        guard isPlaying else { return }
        let frame = window.frame
        let x = (location.x - frame.midX) / max(frame.width / 2, 1)
        let y = (location.y - frame.midY) / max(frame.height / 2, 1)
        surface.setParallax(CGPoint(x: min(max(x, -1), 1), y: min(max(y, -1), 1)))
    }

    func setAudioLevel(_ level: Double) {
        surface.setAudioLevel(isPlaying ? level : 0)
    }

    /// Snaps this display's video to `time` when it has drifted by more than a frame.
    func align(to time: CMTime) {
        guard let player, isPlaying else { return }
        let drift = abs(CMTimeGetSeconds(player.player.currentTime()) - CMTimeGetSeconds(time))
        guard drift > 1.0 / 60 else { return }
        player.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func restack() {
        if window.isVisible { window.orderFrontRegardless() }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        player?.invalidate()
        player = nil
        fileAccess = nil
        soundtrackPlayer?.invalidate()
        soundtrackPlayer = nil
        releaseRetiredPlayers()
        surface.clear()
        window.orderOut(nil)
        window.close()
        request = nil
        status = .empty
    }

    // MARK: - Private

    private func applyInPlace(_ newRequest: WallpaperRenderRequest) {
        request = newRequest
        surface.layout = newRequest.layout
        surface.showsClock = newRequest.showsClock
        applySurfaceEffects()
        player?.setAudio(muted: newRequest.muted, volume: newRequest.volume)
        updateSoundtrack(for: newRequest)
        applyPlaybackState()
    }

    /// Keeps the current soundtrack pipeline when the playlist is unchanged,
    /// so volume changes or re-syncs don't restart the music.
    private func updateSoundtrack(for request: WallpaperRenderRequest) {
        if soundtrackPlayer?.urls != request.soundtracks {
            soundtrackPlayer?.invalidate()
            soundtrackPlayer = request.soundtracks.isEmpty ? nil : SoundtrackPlayer(urls: request.soundtracks)
        }
        soundtrackPlayer?.setVolume(request.volume)
    }

    private func didReveal(fadeInWindow: Bool, duration: TimeInterval) {
        if fadeInWindow {
            isFadingIn = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                self.window.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.isFadingIn = false
                    // Re-evaluate occlusion now that the window is opaque.
                    self.onVisibilityChange?(self.displayKey)
                }
            })
        } else {
            window.alphaValue = 1
        }
        if case .loading = status {
            setStatus(wantsPlaying ? .playing : .paused)
        }
        onVisibilityChange?(displayKey)
    }

    private func applyPlaybackState() {
        guard let player else { return }
        if wantsPlaying {
            player.play(rate: rate)
            soundtrackPlayer?.play()
        } else {
            player.pause()
            soundtrackPlayer?.pause()
        }
        switch status {
        case .playing, .paused:
            setStatus(wantsPlaying ? .playing : .paused)
        case .empty, .loading, .failed:
            break
        }
    }

    private func releaseRetiredPlayers() {
        for (oldPlayer, _) in retiring where oldPlayer !== player {
            oldPlayer.invalidate()
        }
        retiring.removeAll { $0.0 !== player }   // drops their ScopedFileAccess too
    }

    private func setStatus(_ newStatus: RendererStatus) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(displayKey)
    }
}
