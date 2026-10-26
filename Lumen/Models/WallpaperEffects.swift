import CoreGraphics
import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is missing or malformed,
    /// so adding a field never resets a user's existing preferences.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Effects

struct RGBColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let amber = RGBColor(red: 1.0, green: 0.62, blue: 0.28)
}

enum ClockPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, center, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .center: "Center"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// Clock and date drawn on the wallpaper (below desktop icons and windows).
struct ClockOverlay: Codable, Equatable, Hashable, Sendable {
    var enabled = false
    var showDate = true
    var position: ClockPosition = .center
    /// Multiplier on the base size (a tenth of the display height).
    var size: Double = 1.0
    var onAllDisplays = false

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, showDate, position, size, onAllDisplays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClockOverlay()
        enabled = c.value(.enabled, or: d.enabled)
        showDate = c.value(.showDate, or: d.showDate)
        position = c.value(.position, or: d.position)
        size = c.value(.size, or: d.size)
        onAllDisplays = c.value(.onAllDisplays, or: d.onAllDisplays)
    }
}

/// Live, non-destructive adjustments applied on top of every wallpaper.
struct WallpaperEffects: Codable, Equatable, Hashable, Sendable {
    /// Gaussian blur radius in points.
    var blur: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var tint: RGBColor = .amber
    var tintAmount: Double = 0
    var vignette: Double = 0
    var dimInDarkMode = false
    var darkModeDim: Double = 0.35
    var parallax = false
    var parallaxAmount: Double = 0.5
    var clock = ClockOverlay()
    /// Requires microphone permission; off until the user turns it on.
    var audioReactive = false
    var audioReactiveIntensity: Double = 0.5

    init() {}

    /// True when Core Image filters are needed (they cost GPU time, so the
    /// plain path is kept whenever possible).
    var needsFilters: Bool {
        blur > 0.05 || abs(brightness) > 0.001 || abs(contrast - 1) > 0.001
            || abs(saturation - 1) > 0.001 || tintAmount > 0.001
    }

    mutating func sanitize() {
        blur = min(max(blur, 0), 40)
        brightness = min(max(brightness, -0.5), 0.5)
        contrast = min(max(contrast, 0.5), 1.5)
        saturation = min(max(saturation, 0), 2)
        tintAmount = min(max(tintAmount, 0), 1)
        vignette = min(max(vignette, 0), 1)
        darkModeDim = min(max(darkModeDim, 0), 0.8)
        parallaxAmount = min(max(parallaxAmount, 0), 1)
        clock.size = min(max(clock.size, 0.4), 2.5)
        audioReactiveIntensity = min(max(audioReactiveIntensity, 0), 1)
    }

    /// Resets the picture adjustments, leaving clock, parallax, and audio settings alone.
    mutating func resetAdjustments() {
        let d = WallpaperEffects()
        blur = d.blur
        brightness = d.brightness
        contrast = d.contrast
        saturation = d.saturation
        tintAmount = d.tintAmount
        vignette = d.vignette
    }

    private enum CodingKeys: String, CodingKey {
        case blur, brightness, contrast, saturation, tint, tintAmount, vignette
        case dimInDarkMode, darkModeDim, parallax, parallaxAmount, clock
        case audioReactive, audioReactiveIntensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperEffects()
        blur = c.value(.blur, or: d.blur)
        brightness = c.value(.brightness, or: d.brightness)
        contrast = c.value(.contrast, or: d.contrast)
        saturation = c.value(.saturation, or: d.saturation)
        tint = c.value(.tint, or: d.tint)
        tintAmount = c.value(.tintAmount, or: d.tintAmount)
        vignette = c.value(.vignette, or: d.vignette)
        dimInDarkMode = c.value(.dimInDarkMode, or: d.dimInDarkMode)
        darkModeDim = c.value(.darkModeDim, or: d.darkModeDim)
        parallax = c.value(.parallax, or: d.parallax)
        parallaxAmount = c.value(.parallaxAmount, or: d.parallaxAmount)
        clock = c.value(.clock, or: d.clock)
        audioReactive = c.value(.audioReactive, or: d.audioReactive)
        audioReactiveIntensity = c.value(.audioReactiveIntensity, or: d.audioReactiveIntensity)
        sanitize()
    }
}

/// What a surface needs to draw effects, with system state (dark mode) already resolved.
struct SurfaceEffects: Equatable, Sendable {
    var effects = WallpaperEffects()
    /// Opacity of the black dimming layer.
    var dim: Double = 0
}

// MARK: - Performance

enum FrameRateCap: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fps24 = 24, fps30 = 30, fps60 = 60, native = 0

    var id: Int { rawValue }

    var fps: Double? { self == .native ? nil : Double(rawValue) }

    var title: String { self == .native ? "Source (Native)" : "\(rawValue) fps" }
}

// MARK: - Multi-display layout

/// Per-display framing on top of the scaling mode.
struct ContentPosition: Codable, Equatable, Hashable, Sendable {
    /// 1 = the scaling mode's natural size.
    var zoom: Double = 1
    /// -1 aligns the video's left edge with the screen's, 1 its right edge.
    var offsetX: Double = 0
    /// -1 aligns the video's bottom edge with the screen's, 1 its top edge.
    var offsetY: Double = 0

    static let centered = ContentPosition()

    var isCentered: Bool { self == .centered }

    mutating func sanitize() {
        zoom = min(max(zoom, 1), 3)
        offsetX = min(max(offsetX, -1), 1)
        offsetY = min(max(offsetY, -1), 1)
    }
}

/// One video stretched across every connected display.
struct SpanConfiguration: Codable, Equatable, Hashable, Sendable {
    var wallpaperID: UUID
    var scaling: ScalingMode = .fill
    var position: ContentPosition?
}

/// Where a video is drawn on one display. Pure geometry, so it is unit-testable.
///
/// `canvas` is in units of the display's size (origin bottom-left, like
/// AppKit): `(0, 0, 1, 1)` is the display itself; a spanned wallpaper uses
/// the union of all displays expressed relative to this one.
struct SurfaceLayout: Equatable, Sendable {
    var canvas = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The video's display size in pixels (zero when unknown).
    var videoSize: CGSize = .zero
    var scaling: ScalingMode = .fill
    var position: ContentPosition = .centered

    var hasKnownVideoSize: Bool { videoSize.width > 0 && videoSize.height > 0 }

    /// The video layer's frame inside a surface of `bounds` size.
    func videoFrame(in bounds: CGSize) -> CGRect {
        let target = CGRect(x: canvas.minX * bounds.width, y: canvas.minY * bounds.height,
                            width: canvas.width * bounds.width, height: canvas.height * bounds.height)
        guard target.width > 0, target.height > 0 else { return .zero }
        let video = hasKnownVideoSize ? videoSize : target.size

        var size: CGSize
        switch scaling {
        case .fill:
            let scale = max(target.width / video.width, target.height / video.height)
            size = CGSize(width: video.width * scale, height: video.height * scale)
        case .fit:
            let scale = min(target.width / video.width, target.height / video.height)
            size = CGSize(width: video.width * scale, height: video.height * scale)
        case .stretch:
            size = target.size
        }
        size.width *= position.zoom
        size.height *= position.zoom

        // Positive overflow: the video is larger than the target and can be
        // panned; negative: it is letterboxed and can be pushed to an edge.
        let overflowX = (size.width - target.width) / 2
        let overflowY = (size.height - target.height) / 2
        return CGRect(x: target.midX - size.width / 2 - overflowX * position.offsetX,
                      y: target.midY - size.height / 2 - overflowY * position.offsetY,
                      width: size.width, height: size.height)
    }

    /// The canvas covering `union` (all displays), relative to `display`.
    static func spanCanvas(union: CGRect, display: CGRect) -> CGRect {
        guard display.width > 0, display.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (union.minX - display.minX) / display.width,
                      y: (union.minY - display.minY) / display.height,
                      width: union.width / display.width,
                      height: union.height / display.height)
    }
}
