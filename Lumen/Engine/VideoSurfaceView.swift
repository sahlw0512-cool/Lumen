import AppKit
import AVFoundation
import CoreImage

/// Layer-hosting view that presents `AVPlayerLayer`s and performs GPU
/// crossfades between them. A new layer is only revealed once
/// `isReadyForDisplay` reports a decoded frame, so switching wallpapers never
/// flashes black.
///
/// Layer tree (bottom to top):
/// - `contentLayer`: the video layers, Core Image adjustments, and the
///   parallax / audio-pulse transform
/// - `dimLayer`, `vignetteLayer`, `pulseLayer`: cheap overlays
/// - `clockLayer`: unaffected by blur and movement
final class VideoSurfaceView: NSView {
    private var visibleLayer: AVPlayerLayer?
    private var pendingLayer: AVPlayerLayer?
    private var readyObservation: NSKeyValueObservation?
    private var fallbackTask: Task<Void, Never>?
    private var presentationToken = UUID()

    private let contentLayer = CALayer()
    private let dimLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    private let pulseLayer = CALayer()
    private let clockLayer = CATextLayer()

    private var parallax = CGPoint.zero
    private var audioLevel: Double = 0
    private var clockTime = ""
    private var clockDate = ""

    var layout = SurfaceLayout() {
        didSet {
            guard layout != oldValue else { return }
            layoutVideoLayers()
        }
    }

    var effects = SurfaceEffects() {
        didSet {
            guard effects != oldValue else { return }
            applyEffects()
        }
    }

    var showsClock = false {
        didSet {
            guard showsClock != oldValue else { return }
            updateClock()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.actions = ["sublayers": NSNull(), "contents": NSNull()]
        layer = root       // set before wantsLayer: makes this a layer-hosting view
        wantsLayer = true
        layerUsesCoreImageFilters = true
        autoresizingMask = [.width, .height]

        let noAnimation: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
            "opacity": NSNull(), "filters": NSNull(), "transform": NSNull(), "colors": NSNull(),
        ]
        for overlay in [contentLayer, dimLayer, vignetteLayer, pulseLayer, clockLayer] as [CALayer] {
            overlay.actions = noAnimation
            overlay.frame = bounds
            root.addSublayer(overlay)
        }
        contentLayer.actions?["sublayers"] = NSNull()
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        vignetteLayer.type = .radial
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1.2, y: 1.2)
        vignetteLayer.locations = [0.35, 1.0]
        vignetteLayer.opacity = 0
        pulseLayer.backgroundColor = NSColor.white.cgColor
        pulseLayer.opacity = 0
        clockLayer.isWrapped = false
        clockLayer.shadowColor = NSColor.black.cgColor
        clockLayer.shadowOpacity = 0.45
        clockLayer.shadowRadius = 12
        clockLayer.shadowOffset = .zero
        clockLayer.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }

    /// Never participate in hit-testing; the desktop beneath must get every click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for overlay in [contentLayer, dimLayer, vignetteLayer, pulseLayer] {
            overlay.frame = bounds
        }
        layoutVideoLayers()
        updateContentTransform(animated: false)
        updateClock()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        visibleLayer?.contentsScale = scale
        pendingLayer?.contentsScale = scale
        clockLayer.contentsScale = scale
    }

    /// Presents `player`. `onReveal` fires when the first frame is on screen;
    /// `onTransitionComplete` fires once the previous layer has been removed.
    func present(player: AVPlayer, crossfade: TimeInterval,
                 onReveal: @escaping @MainActor () -> Void,
                 onTransitionComplete: @escaping @MainActor () -> Void) {
        cancelPending()
        let token = UUID()
        presentationToken = token

        let newLayer = AVPlayerLayer(player: player)
        newLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        newLayer.opacity = 0
        newLayer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        configure(newLayer)
        contentLayer.addSublayer(newLayer)
        pendingLayer = newLayer

        readyObservation = newLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                self?.reveal(token: token, crossfade: crossfade, onReveal: onReveal, onTransitionComplete: onTransitionComplete)
            }
        }
        // Never get stuck invisible if a file is slow or the ready signal is missed.
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.reveal(token: token, crossfade: crossfade, onReveal: onReveal, onTransitionComplete: onTransitionComplete)
        }
    }

    /// Removes every layer (used when the display's wallpaper is cleared).
    func clear() {
        cancelPending()
        presentationToken = UUID()
        visibleLayer?.removeFromSuperlayer()
        visibleLayer?.player = nil
        visibleLayer = nil
    }

    // MARK: - Effects

    func setClock(time: String, date: String) {
        guard time != clockTime || date != clockDate else { return }
        clockTime = time
        clockDate = date
        updateClock()
    }

    /// `offset` is the pointer position relative to this display, each axis in -1...1.
    func setParallax(_ offset: CGPoint) {
        // Steps of 2% ignore jitter and tiny movements that wouldn't be visible.
        let quantized = CGPoint(x: (offset.x * 50).rounded() / 50, y: (offset.y * 50).rounded() / 50)
        guard quantized != parallax else { return }
        parallax = quantized
        updateContentTransform(animated: true)
    }

    func setAudioLevel(_ level: Double) {
        let level = effects.effects.audioReactive ? level : 0
        guard abs(level - audioLevel) > 0.002 else { return }
        audioLevel = level
        updateContentTransform(animated: false)
        pulseLayer.opacity = Float(level * 0.12 * effects.effects.audioReactiveIntensity)
    }

    private func applyEffects() {
        let fx = effects.effects
        contentLayer.filters = fx.needsFilters ? Self.filters(for: fx) : nil
        dimLayer.opacity = Float(effects.dim)
        vignetteLayer.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                                NSColor.black.withAlphaComponent(0.92).cgColor]
        vignetteLayer.opacity = Float(fx.vignette)
        if !fx.audioReactive { setAudioLevel(0) }
        if !fx.parallax { parallax = .zero }
        updateContentTransform(animated: false)
        updateClock()
    }

    private static func filters(for fx: WallpaperEffects) -> [CIFilter] {
        var filters: [CIFilter] = []
        if let color = CIFilter(name: "CIColorControls") {
            color.setDefaults()
            color.setValue(fx.brightness, forKey: kCIInputBrightnessKey)
            color.setValue(fx.contrast, forKey: kCIInputContrastKey)
            color.setValue(fx.saturation, forKey: kCIInputSaturationKey)
            filters.append(color)
        }
        if fx.tintAmount > 0.001, let tint = CIFilter(name: "CIColorMonochrome") {
            tint.setDefaults()
            tint.setValue(CIColor(red: fx.tint.red, green: fx.tint.green, blue: fx.tint.blue), forKey: kCIInputColorKey)
            tint.setValue(fx.tintAmount, forKey: kCIInputIntensityKey)
            filters.append(tint)
        }
        if fx.blur > 0.05, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setDefaults()
            blur.setValue(fx.blur, forKey: kCIInputRadiusKey)
            filters.append(blur)
        }
        return filters
    }

    /// Scale and translation of the video: room for parallax travel, hiding
    /// the soft edges a blur leaves, and the audio pulse.
    private func updateContentTransform(animated: Bool) {
        let fx = effects.effects
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let travel = fx.parallax ? 0.035 * fx.parallaxAmount : 0
        let blurMargin = fx.blur > 0.05 ? (fx.blur * 3) / min(size.width, size.height) : 0
        let pulse = audioLevel * 0.035 * fx.audioReactiveIntensity
        let scale = 1 + 2 * travel + 2 * blurMargin + pulse

        // Move against the pointer, like looking through a window.
        let dx = -parallax.x * travel * size.width
        let dy = -parallax.y * travel * size.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)

        CATransaction.begin()
        if animated {
            // With no from/to values, Core Animation glides from wherever the
            // layer currently is on screen to the new value, so successive
            // updates blend without reading the presentation layer.
            let animation = CABasicAnimation(keyPath: "transform")
            animation.duration = 0.45
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.setDisableActions(true)
            contentLayer.add(animation, forKey: "parallax")
        } else {
            CATransaction.setDisableActions(true)
        }
        contentLayer.transform = transform
        CATransaction.commit()
    }

    private func updateClock() {
        let clock = effects.effects.clock
        guard showsClock, clock.enabled, !clockTime.isEmpty, bounds.height > 0 else {
            clockLayer.isHidden = true
            return
        }
        let base = bounds.height * 0.1 * clock.size
        let text = NSMutableAttributedString(string: clockTime, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: base, weight: .thin),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        if clock.showDate, !clockDate.isEmpty {
            text.append(NSAttributedString(string: "\n" + clockDate, attributes: [
                .font: NSFont.systemFont(ofSize: base * 0.24, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]))
        }
        // CATextLayer aligns lines by its own alignmentMode, not paragraph styles.
        switch clock.position {
        case .topLeft, .bottomLeft: clockLayer.alignmentMode = .left
        case .topRight, .bottomRight: clockLayer.alignmentMode = .right
        case .center: clockLayer.alignmentMode = .center
        }

        let size = text.boundingRect(with: CGSize(width: bounds.width, height: bounds.height),
                                     options: [.usesLineFragmentOrigin]).integral.size
        let margin = bounds.height * 0.06
        let origin: CGPoint
        switch clock.position {
        case .topLeft: origin = CGPoint(x: margin, y: bounds.height - margin - size.height)
        case .topRight: origin = CGPoint(x: bounds.width - margin - size.width, y: bounds.height - margin - size.height)
        case .center: origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        case .bottomLeft: origin = CGPoint(x: margin, y: margin)
        case .bottomRight: origin = CGPoint(x: bounds.width - margin - size.width, y: margin)
        }
        clockLayer.contentsScale = window?.backingScaleFactor ?? 2
        clockLayer.string = text
        clockLayer.frame = CGRect(origin: origin, size: size)
        clockLayer.isHidden = false
    }

    // MARK: - Layout

    private func configure(_ playerLayer: AVPlayerLayer) {
        // With a known video size the frame is already aspect-correct, so
        // `.resize` lets panning and spanning place it exactly.
        playerLayer.videoGravity = layout.hasKnownVideoSize ? .resize : layout.scaling.videoGravity
        playerLayer.frame = layout.videoFrame(in: bounds.size)
    }

    private func layoutVideoLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let visibleLayer { configure(visibleLayer) }
        if let pendingLayer { configure(pendingLayer) }
        CATransaction.commit()
    }

    private func reveal(token: UUID, crossfade: TimeInterval,
                        onReveal: @MainActor () -> Void,
                        onTransitionComplete: @escaping @MainActor () -> Void) {
        guard token == presentationToken, let incoming = pendingLayer else { return }
        readyObservation?.invalidate()
        readyObservation = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        pendingLayer = nil

        let outgoing = visibleLayer
        visibleLayer = incoming

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            outgoing?.removeFromSuperlayer()
            outgoing?.player = nil
            Task { @MainActor in onTransitionComplete() }
        }
        if crossfade > 0 && outgoing != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = crossfade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.add(fade, forKey: "crossfade")
        }
        incoming.opacity = 1
        CATransaction.commit()

        onReveal()
    }

    private func cancelPending() {
        readyObservation?.invalidate()
        readyObservation = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        pendingLayer?.removeFromSuperlayer()
        pendingLayer?.player = nil
        pendingLayer = nil
    }
}
