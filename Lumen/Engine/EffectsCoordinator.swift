import AppKit

/// Drives the time-varying effects (clock, parallax, audio reactivity, dark
/// mode dimming) for every surface. Each source only runs while its effect is
/// on and a wallpaper is actually playing, so a paused or plain wallpaper
/// costs nothing.
@MainActor
final class EffectsCoordinator {
    let audio = AudioLevelMonitor()

    private unowned let renderer: any WallpaperRenderer
    private var effects = WallpaperEffects()
    /// A wallpaper is playing: motion and audio effects run.
    private var isActive = false
    /// A wallpaper is on screen (playing or paused): the clock keeps time.
    private var isShowing = false
    private var isDarkMode = false
    private var appearanceObservation: NSKeyValueObservation?
    private var clockTimer: Timer?
    private var pointerTimer: Timer?
    private var lastPointer = CGPoint.zero
    private var stillSince: Date?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    init(renderer: any WallpaperRenderer) {
        self.renderer = renderer
        isDarkMode = Self.systemIsDark()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }
        audio.onLevel = { [weak self] level in self?.renderer.setAudioLevel(level) }
    }

    func update(effects newEffects: WallpaperEffects, active: Bool, showing: Bool) {
        let changed = newEffects != effects || active != isActive || showing != isShowing
        effects = newEffects
        isActive = active
        isShowing = showing
        guard changed else { return }
        pushSurfaceEffects()
        updateClock()
        updatePointerTracking()
        updateAudio()
    }

    func stop() {
        update(effects: WallpaperEffects(), active: false, showing: false)
        appearanceObservation?.invalidate()
        appearanceObservation = nil
    }

    // MARK: - Dark mode

    private static func systemIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func appearanceChanged() {
        let dark = Self.systemIsDark()
        guard dark != isDarkMode else { return }
        isDarkMode = dark
        pushSurfaceEffects()
    }

    private func pushSurfaceEffects() {
        let dim = effects.dimInDarkMode && isDarkMode ? effects.darkModeDim : 0
        renderer.setEffects(SurfaceEffects(effects: effects, dim: dim))
    }

    // MARK: - Clock

    /// Ticks on minute boundaries, only while the clock is visible.
    private func updateClock() {
        let wanted = effects.clock.enabled && isShowing
        guard wanted else {
            clockTimer?.invalidate()
            clockTimer = nil
            return
        }
        renderClock()
        guard clockTimer == nil else { return }
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clockTimer = nil
                self.renderClock()
                if self.effects.clock.enabled && self.isShowing { self.scheduleNextTick() }
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func renderClock() {
        let now = Date()
        renderer.setClock(time: timeFormatter.string(from: now), date: dateFormatter.string(from: now))
    }

    // MARK: - Parallax

    /// Reads the pointer position on a timer instead of listening to
    /// mouse-moved events: macOS delivers those at the mouse's own rate (120 Hz
    /// on ProMotion, up to 1,000 Hz for some mice), and waking for each one
    /// costs far more than the parallax itself. The timer runs 15 times a second
    /// while the pointer moves and drops to 4 when it's still; the surfaces
    /// glide between readings.
    private func updatePointerTracking() {
        let wanted = effects.parallax && isActive
        if wanted, pointerTimer == nil {
            lastPointer = NSEvent.mouseLocation
            renderer.setPointer(lastPointer)
            schedulePointerPoll(after: Self.movingInterval)
        } else if !wanted, pointerTimer != nil {
            pointerTimer?.invalidate()
            pointerTimer = nil
            renderer.setPointer(nil)
        }
    }

    private static let movingInterval: TimeInterval = 1.0 / 15
    private static let stillInterval: TimeInterval = 0.25

    private func schedulePointerPoll(after interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func pollPointer() {
        guard pointerTimer != nil else { return }
        let location = NSEvent.mouseLocation
        let moved = hypot(location.x - lastPointer.x, location.y - lastPointer.y) >= 2
        if moved {
            lastPointer = location
            stillSince = nil
            renderer.setPointer(location)
        } else if stillSince == nil {
            stillSince = Date()
        }
        let isStill = stillSince.map { Date().timeIntervalSince($0) > 1 } ?? false
        schedulePointerPoll(after: isStill ? Self.stillInterval : Self.movingInterval)
    }

    // MARK: - Audio

    private func updateAudio() {
        if effects.audioReactive && isActive {
            audio.start()
        } else {
            audio.stop()
            renderer.setAudioLevel(0)
        }
    }
}
