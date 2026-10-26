import Foundation

/// Why a display's wallpaper is paused. Ordered by precedence.
enum PauseReason: String, CaseIterable, Sendable {
    case userPaused
    case systemAsleep
    case sessionInactive
    case screenLocked
    case screenSaver
    case displayAsleep
    case thermalPressure
    case lowPowerMode
    case onBattery
    case userIdle
    case appHidden
    case fullscreenApp
    case covered

    var title: String {
        switch self {
        case .userPaused: "Paused"
        case .systemAsleep: "Mac is asleep"
        case .sessionInactive: "Another user is active"
        case .screenLocked: "Screen locked"
        case .screenSaver: "Screen saver running"
        case .displayAsleep: "Display asleep"
        case .thermalPressure: "Mac is running hot"
        case .lowPowerMode: "Low Power Mode"
        case .onBattery: "On battery power"
        case .userIdle: "You're away"
        case .appHidden: "Lumen is hidden"
        case .fullscreenApp: "Fullscreen app"
        case .covered: "Covered by windows"
        }
    }
}

/// Inputs to the pause decision for one display. Pure data, so the policy is
/// trivially unit-testable.
struct PlaybackConditions: Equatable {
    var userPaused = false
    var systemAsleep = false
    var sessionActive = true
    var screenLocked = false
    var screenSaverRunning = false
    var displayAsleep = false
    var thermalPressure = false
    var lowPowerMode = false
    var onBattery = false
    var userIdle = false
    var appHidden = false
    var fullscreenOnDisplay = false
    var surfaceVisible = true
}

enum PlaybackPolicy {
    /// Returns nil when the wallpaper should play.
    /// Sleep, lock, screen saver, and inactive sessions always pause: nothing
    /// is visible, and the wallpaper must never compete with security UI.
    static func pauseReason(for c: PlaybackConditions, settings: AppSettings) -> PauseReason? {
        if c.userPaused { return .userPaused }
        if c.systemAsleep { return .systemAsleep }
        if !c.sessionActive { return .sessionInactive }
        if c.screenLocked { return .screenLocked }
        if c.screenSaverRunning { return .screenSaver }
        if c.displayAsleep && settings.pauseWhenDisplaySleeps { return .displayAsleep }
        if c.thermalPressure && settings.pauseUnderThermalPressure { return .thermalPressure }
        if c.lowPowerMode && settings.pauseInLowPowerMode { return .lowPowerMode }
        if c.onBattery && settings.pauseOnBattery { return .onBattery }
        if c.userIdle && settings.pauseWhenIdle { return .userIdle }
        if c.appHidden && settings.pauseWhenAppHidden { return .appHidden }
        if c.fullscreenOnDisplay && settings.pauseWhenFullscreen { return .fullscreenApp }
        if !c.surfaceVisible && settings.pauseWhenOccluded { return .covered }
        return nil
    }

    /// Frame rate used for "lower frame rate" power savings.
    static let reducedFrameRate: Double = 15

    /// The frame-rate ceiling for a playing wallpaper, or nil for the video's own rate.
    /// The lowest applicable limit wins.
    static func frameRateCap(for c: PlaybackConditions, settings: AppSettings) -> Double? {
        var caps: [Double] = []
        if let fps = settings.maxFrameRate.fps { caps.append(fps) }
        if c.onBattery && settings.lowerFrameRateOnBattery, let fps = settings.batteryFrameRate.fps { caps.append(fps) }
        if c.userIdle && settings.lowerFrameRateWhenIdle { caps.append(reducedFrameRate) }
        if c.appHidden && settings.lowerFrameRateWhenHidden { caps.append(reducedFrameRate) }
        return caps.min()
    }
}
