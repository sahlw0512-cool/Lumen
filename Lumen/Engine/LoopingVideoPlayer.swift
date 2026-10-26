import AVFoundation

/// One AVFoundation playback pipeline for one desktop surface.
///
/// - `AVQueuePlayer` + `AVPlayerLooper` gives gapless looping: the looper keeps
///   the next replica item pre-rolled, so there is no seek and no black frame
///   at the loop point.
/// - Decoding goes through VideoToolbox (hardware where supported). Frames are
///   delivered straight to `AVPlayerLayer` as IOSurfaces and composited by the
///   window server: no CPU copies, no per-frame app code, no display link.
/// - When paused, nothing decodes or renders.
@MainActor
final class LoopingVideoPlayer {
    let player: AVQueuePlayer
    let url: URL
    var onFailure: ((String) -> Void)?

    private var looper: AVPlayerLooper?
    private var frameRateCap: Double?
    private var capTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    /// The loop's own compositing (crossfade), which a frame-rate cap must keep.
    private var loopComposition: AVVideoComposition?
    private var audioMix: AVAudioMix?
    private var observations: [NSKeyValueObservation] = []
    private var failureObserver: NSObjectProtocol?
    private(set) var isInvalidated = false

    init(url: URL, loopMode: LoopMode, loop: LoopSettings = LoopSettings()) {
        self.url = url
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        // A wallpaper must never keep the display awake or route to AirPlay.
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.allowsExternalPlayback = false
        // Local files: start immediately instead of waiting to build a buffer.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        player = queuePlayer
        observeFailures()

        if loop.isPlain {
            install(LoopComposition(asset: AVURLAsset(url: url), timeRange: nil, videoComposition: nil, audioMix: nil), loopMode: loopMode)
        } else {
            // Trimmed or crossfaded loops need the asset's tracks first. The
            // surface waits for the first decoded frame, so this stays invisible.
            buildTask = Task { [weak self] in
                do {
                    let composition = try await LoopComposer.make(url: url, settings: loop)
                    guard let self, !self.isInvalidated else { return }
                    self.install(composition, loopMode: loopMode)
                } catch {
                    self?.report("Couldn't prepare the loop: \(error.localizedDescription)")
                }
            }
        }
    }

    private func install(_ composition: LoopComposition, loopMode: LoopMode) {
        let item = AVPlayerItem(asset: composition.asset)
        item.videoComposition = composition.videoComposition
        item.audioMix = composition.audioMix
        loopComposition = composition.videoComposition
        audioMix = composition.audioMix

        switch loopMode {
        case .loop:
            let looper = composition.timeRange.map { AVPlayerLooper(player: player, templateItem: item, timeRange: $0) }
                ?? AVPlayerLooper(player: player, templateItem: item)
            self.looper = looper
            observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let message = looper.error?.localizedDescription ?? "The video could not be looped."
                Task { @MainActor in self?.report(message) }
            })
        case .playOnce:
            player.actionAtItemEnd = .pause
            if let range = composition.timeRange {
                item.forwardPlaybackEndTime = range.end
                item.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            }
            player.insert(item, after: nil)
        }
        applyCurrentComposition()
    }

    func play(rate: Float) {
        guard !isInvalidated else { return }
        player.defaultRate = rate
        if player.timeControlStatus == .playing && player.rate == rate { return }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        guard !isInvalidated, player.timeControlStatus != .paused || player.rate != 0 else { return }
        player.pause()
    }

    func setAudio(muted: Bool, volume: Float) {
        player.isMuted = muted
        player.volume = volume
    }

    /// Limits how often new frames are composited (nil = the source rate).
    /// Applied to the live items, so playback continues without a reload.
    func setFrameRateCap(_ fps: Double?) {
        guard !isInvalidated, fps != frameRateCap else { return }
        frameRateCap = fps
        applyCurrentComposition()
    }

    /// Applies the loop's compositing combined with any frame-rate cap.
    private func applyCurrentComposition() {
        capTask?.cancel()
        guard let fps = frameRateCap else {
            applyVideoComposition(loopComposition)
            return
        }
        if let loopComposition, let capped = loopComposition.mutableCopy() as? AVMutableVideoComposition {
            let capDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            if CMTimeCompare(capDuration, loopComposition.frameDuration) > 0 { capped.frameDuration = capDuration }
            applyVideoComposition(capped)
            return
        }
        let asset = AVURLAsset(url: url)
        capTask = Task { [weak self] in
            let sourceRate = try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)
            // At or below the cap already: a composition would only add GPU work.
            if let sourceRate, sourceRate > 0, Double(sourceRate) <= fps + 0.5 {
                guard !Task.isCancelled else { return }
                self?.applyVideoComposition(nil)
                return
            }
            guard let composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset),
                  !Task.isCancelled, let self, !self.isInvalidated, self.frameRateCap == fps,
                  self.loopComposition == nil else { return }
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            self.applyVideoComposition(composition)
            Log.debug("Frame rate capped at \(Int(fps)) fps for \(self.url.lastPathComponent)", category: "engine")
        }
    }

    private func applyVideoComposition(_ composition: AVVideoComposition?) {
        let items = looper?.loopingPlayerItems ?? player.items()
        for item in items {
            if item.videoComposition !== composition { item.videoComposition = composition }
            if item.audioMix !== audioMix { item.audioMix = audioMix }
        }
    }

    /// Releases decoders and file handles. Safe to call more than once.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        capTask?.cancel()
        capTask = nil
        buildTask?.cancel()
        buildTask = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        onFailure = nil
    }

    private func observeFailures() {
        observations.append(player.observe(\.status, options: [.new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            let message = player.error?.localizedDescription ?? "The player failed."
            Task { @MainActor in self?.report(message) }
        })
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "Playback stopped unexpectedly."
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, self.player.items().contains(item) else { return }
                self.report(message)
            }
        }
    }

    private func report(_ message: String) {
        guard !isInvalidated else { return }
        Log.error("Playback failure: \(message)", category: "engine")
        onFailure?(message)
    }
}
