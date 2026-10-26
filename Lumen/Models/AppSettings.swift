import AVFoundation
import SwiftUI

enum ScalingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill, fit, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }

    var detail: String {
        switch self {
        case .fill: "Crop to fill the screen, preserving aspect ratio"
        case .fit: "Show the whole video, letterboxing if needed"
        case .stretch: "Distort the video to exactly cover the screen"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

enum LoopMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case loop, playOnce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "Loop Seamlessly"
        case .playOnce: "Play Once, Hold Last Frame"
        }
    }
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// All user preferences. Decoding tolerates missing keys so that adding a
/// setting in a later version never resets the user's existing preferences.
struct AppSettings: Codable, Equatable, Sendable {
    var defaultScaling: ScalingMode = .fill
    var loopMode: LoopMode = .loop
    var playbackRate: Double = 1.0
    var crossfadeTransitions = true

    var audioEnabled = false
    var audioVolume: Double = 0.5

    var pauseOnBattery = false
    var pauseInLowPowerMode = true
    var pauseUnderThermalPressure = true
    var pauseWhenFullscreen = true
    var pauseWhenOccluded = true
    var pauseWhenDisplaySleeps = true
    var pauseWhenAppHidden = false
    var pauseWhenIdle = false
    var idleMinutes: Int = 10

    var syncStaticDesktopPicture = false
    /// Which frame the lock screen and login window show.
    var lockScreenFrame: LockScreenFrame = .latest
    var warnAboutSoftwareDecoding = true
    var hideDesktopIcons = false

    var showMenuBarItem = true
    var showInDock = true
    var appearance: AppearancePreference = .dark

    var effects = WallpaperEffects()

    var maxFrameRate: FrameRateCap = .native
    var lowerFrameRateOnBattery = false
    var batteryFrameRate: FrameRateCap = .fps30
    /// Used when the matching pause setting is off: keep playing, but slower.
    var lowerFrameRateWhenIdle = false
    var lowerFrameRateWhenHidden = false

    /// User-made effect presets (built-ins are not stored).
    var effectPresets: [EffectPreset] = []
    var globalHotkeysEnabled = false
    /// Leave the chosen frame as the macOS picture after quitting, so the
    /// login window shows it after logging out or restarting.
    var keepLockScreenPictureAfterQuit = true
    var hasCompletedOnboarding = false
    var location: Coordinates?
    var iCloudSyncEnabled = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultScaling, loopMode, playbackRate, crossfadeTransitions
        case audioEnabled, audioVolume
        case pauseOnBattery, pauseInLowPowerMode, pauseUnderThermalPressure, pauseWhenFullscreen
        case pauseWhenOccluded, pauseWhenDisplaySleeps, pauseWhenAppHidden, pauseWhenIdle, idleMinutes
        case syncStaticDesktopPicture, lockScreenFrame, warnAboutSoftwareDecoding, hideDesktopIcons
        case showMenuBarItem, showInDock, appearance
        case effects, maxFrameRate, lowerFrameRateOnBattery, batteryFrameRate
        case lowerFrameRateWhenIdle, lowerFrameRateWhenHidden
        case effectPresets, globalHotkeysEnabled, keepLockScreenPictureAfterQuit, hasCompletedOnboarding
        case location, iCloudSyncEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultScaling = (try? c.decodeIfPresent(ScalingMode.self, forKey: .defaultScaling)) ?? d.defaultScaling
        loopMode = (try? c.decodeIfPresent(LoopMode.self, forKey: .loopMode)) ?? d.loopMode
        playbackRate = (try? c.decodeIfPresent(Double.self, forKey: .playbackRate)) ?? d.playbackRate
        crossfadeTransitions = (try? c.decodeIfPresent(Bool.self, forKey: .crossfadeTransitions)) ?? d.crossfadeTransitions
        audioEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .audioEnabled)) ?? d.audioEnabled
        audioVolume = (try? c.decodeIfPresent(Double.self, forKey: .audioVolume)) ?? d.audioVolume
        pauseOnBattery = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery)) ?? d.pauseOnBattery
        pauseInLowPowerMode = (try? c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode)) ?? d.pauseInLowPowerMode
        pauseUnderThermalPressure = (try? c.decodeIfPresent(Bool.self, forKey: .pauseUnderThermalPressure)) ?? d.pauseUnderThermalPressure
        pauseWhenFullscreen = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenFullscreen)) ?? d.pauseWhenFullscreen
        pauseWhenOccluded = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenOccluded)) ?? d.pauseWhenOccluded
        pauseWhenDisplaySleeps = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenDisplaySleeps)) ?? d.pauseWhenDisplaySleeps
        pauseWhenAppHidden = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenAppHidden)) ?? d.pauseWhenAppHidden
        pauseWhenIdle = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenIdle)) ?? d.pauseWhenIdle
        idleMinutes = (try? c.decodeIfPresent(Int.self, forKey: .idleMinutes)) ?? d.idleMinutes
        syncStaticDesktopPicture = (try? c.decodeIfPresent(Bool.self, forKey: .syncStaticDesktopPicture)) ?? d.syncStaticDesktopPicture
        lockScreenFrame = c.value(.lockScreenFrame, or: d.lockScreenFrame)
        warnAboutSoftwareDecoding = (try? c.decodeIfPresent(Bool.self, forKey: .warnAboutSoftwareDecoding)) ?? d.warnAboutSoftwareDecoding
        hideDesktopIcons = (try? c.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons)) ?? d.hideDesktopIcons
        showMenuBarItem = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem)) ?? d.showMenuBarItem
        showInDock = (try? c.decodeIfPresent(Bool.self, forKey: .showInDock)) ?? d.showInDock
        appearance = (try? c.decodeIfPresent(AppearancePreference.self, forKey: .appearance)) ?? d.appearance
        effects = c.value(.effects, or: d.effects)
        maxFrameRate = c.value(.maxFrameRate, or: d.maxFrameRate)
        lowerFrameRateOnBattery = c.value(.lowerFrameRateOnBattery, or: d.lowerFrameRateOnBattery)
        batteryFrameRate = c.value(.batteryFrameRate, or: d.batteryFrameRate)
        lowerFrameRateWhenIdle = c.value(.lowerFrameRateWhenIdle, or: d.lowerFrameRateWhenIdle)
        lowerFrameRateWhenHidden = c.value(.lowerFrameRateWhenHidden, or: d.lowerFrameRateWhenHidden)
        effectPresets = c.value(.effectPresets, or: d.effectPresets)
        globalHotkeysEnabled = c.value(.globalHotkeysEnabled, or: d.globalHotkeysEnabled)
        keepLockScreenPictureAfterQuit = c.value(.keepLockScreenPictureAfterQuit, or: d.keepLockScreenPictureAfterQuit)
        // Existing users already have a library; don't greet them with onboarding.
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, or: true)
        location = c.value(.location, or: d.location)
        iCloudSyncEnabled = c.value(.iCloudSyncEnabled, or: d.iCloudSyncEnabled)
        sanitize()
    }

    /// Clamp values that could have been hand-edited into nonsense.
    mutating func sanitize() {
        playbackRate = min(max(playbackRate, 0.25), 2.0)
        audioVolume = min(max(audioVolume, 0), 1)
        idleMinutes = min(max(idleMinutes, 1), 240)
        if !showInDock && !showMenuBarItem { showMenuBarItem = true }
        effects.sanitize()
        if batteryFrameRate == .native { batteryFrameRate = .fps30 }
    }
}

/// The frame used as the macOS picture for the lock screen and login window.
enum LockScreenFrame: String, Codable, CaseIterable, Sendable {
    /// Wherever the video was when the screen locked, slept, or the screen
    /// saver started, so unlocking picks up from the same frame.
    case latest
    /// The frame picked in the wallpaper's preview.
    case picked

    var title: String {
        switch self {
        case .latest: "Where the video paused"
        case .picked: "The frame you picked"
        }
    }
}
