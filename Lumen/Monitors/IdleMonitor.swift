import AppKit
import Observation

/// Detects when the user has been away from the keyboard and mouse.
///
/// There's no "user became idle" notification, so this schedules a single
/// one-shot timer for the moment the idle threshold could first be reached,
/// based on `CGEventSource.secondsSinceLastEventType`. Activity in between just
/// pushes the next check later. Return from idle is detected with mouse/keyboard
/// event monitors that exist only while idle, plus a slow fallback check
/// (global key monitoring needs Accessibility permission, which Lumen doesn't request).
@MainActor
@Observable
final class IdleMonitor {
    private(set) var isIdle = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var threshold: TimeInterval = 600
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?

    func configure(enabled: Bool, threshold: TimeInterval) {
        let clamped = max(60, threshold)
        guard enabled != self.enabled || clamped != self.threshold else { return }
        self.enabled = enabled
        self.threshold = clamped
        reset()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeEventMonitors()
    }

    static func secondsSinceLastInput() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func reset() {
        stop()
        if isIdle {
            isIdle = false
            onChange?()
        }
        if enabled { check() }
    }

    private func check() {
        guard enabled else { return }
        let idleFor = Self.secondsSinceLastInput()
        if idleFor >= threshold {
            becomeIdle()
        } else {
            schedule(after: threshold - idleFor + 1) { $0.check() }
        }
    }

    private func becomeIdle() {
        guard !isIdle else { return }
        isIdle = true
        Log.info("User idle; pausing if enabled", category: "idle")
        onChange?()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.userReturned() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.userReturned() }
            return event
        }
        scheduleReturnCheck()
    }

    /// Keyboard-only fallback while idle: a check every 15 s, only in the idle state.
    private func scheduleReturnCheck() {
        schedule(after: 15) { monitor in
            guard monitor.isIdle else { return }
            if Self.secondsSinceLastInput() < 15 {
                monitor.userReturned()
            } else {
                monitor.scheduleReturnCheck()
            }
        }
    }

    private func userReturned() {
        guard isIdle else { return }
        removeEventMonitors()
        isIdle = false
        Log.info("User returned from idle", category: "idle")
        onChange?()
        schedule(after: threshold) { $0.check() }
    }

    private func schedule(after interval: TimeInterval, _ action: @escaping @MainActor (IdleMonitor) -> Void) {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        newTimer.tolerance = min(30, interval * 0.2)
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func removeEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
