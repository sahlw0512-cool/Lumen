import AVFoundation
import Observation

/// In-app preview player. Completely independent from the desktop engine, so
/// previewing never interrupts or reloads the wallpaper currently on screen.
@MainActor
@Observable
final class PreviewPlayerModel {
    let player = AVQueuePlayer()

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    private(set) var isScrubbing = false
    /// Playing the loop as it will appear on the desktop (trim + crossfade).
    private(set) var isPreviewingLoop = false

    var isMuted = true {
        didSet { player.isMuted = isMuted }
    }
    var volume: Double = 0.6 {
        didSet { player.volume = Float(volume) }
    }

    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var access: ScopedFileAccess?
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var sourceDuration: Double = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    init() {
        player.isMuted = true
        player.volume = Float(volume)
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func load(url: URL, knownDuration: Double) {
        teardown()
        sourceURL = url
        sourceDuration = knownDuration
        access = ScopedFileAccess(url: url)
        duration = knownDuration
        currentTime = 0
        errorMessage = nil
        isPreviewingLoop = false
        start(item: AVPlayerItem(asset: AVURLAsset(url: url)), timeRange: nil)
    }

    /// Plays the loop exactly as the desktop will (times then refer to the loop, not the file).
    func previewLoop(_ settings: LoopSettings) {
        guard let url = sourceURL else { return }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let composition = try? await LoopComposer.make(url: url, settings: settings), let self, !Task.isCancelled else { return }
            self.stopPlayback()
            let item = AVPlayerItem(asset: composition.asset)
            item.videoComposition = composition.videoComposition
            item.audioMix = composition.audioMix
            self.isPreviewingLoop = true
            let assetLength = (try? await composition.asset.load(.duration).seconds) ?? 0
            let loopLength = composition.timeRange?.duration.seconds ?? assetLength
            self.duration = loopLength
            self.currentTime = 0
            self.start(item: item, timeRange: composition.timeRange)
            // Jump close to the seam so it's visible right away.
            let seam = max(loopLength - 3, 0)
            let base = composition.timeRange?.start.seconds ?? 0
            await self.player.seek(to: CMTime(seconds: base + seam, preferredTimescale: 600))
        }
    }

    /// Back to the original file, at `seconds`.
    func showSource(at seconds: Double = 0) {
        guard let url = sourceURL else { return }
        loopTask?.cancel()
        stopPlayback()
        isPreviewingLoop = false
        duration = sourceDuration
        currentTime = seconds
        start(item: AVPlayerItem(asset: AVURLAsset(url: url)), timeRange: nil)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func start(item: AVPlayerItem, timeRange: CMTimeRange?) {
        looper = timeRange.map { AVPlayerLooper(player: player, templateItem: item, timeRange: $0) }
            ?? AVPlayerLooper(player: player, templateItem: item)
        if let composition = item.videoComposition {
            looper?.loopingPlayerItems.forEach { $0.videoComposition = composition; $0.audioMix = item.audioMix }
        }

        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        })
        if let looper {
            observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let message = looper.error?.localizedDescription ?? "This video can't be previewed."
                Task { @MainActor in self?.errorMessage = message }
            })
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.isNumeric else { return }
                self.currentTime = time.seconds
                if self.duration <= 0, let itemDuration = self.player.currentItem?.duration, itemDuration.isNumeric {
                    self.duration = itemDuration.seconds
                }
            }
        }
        player.play()
    }

    func togglePlay() {
        isPlaying ? player.pause() : player.play()
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        player.pause()
    }

    /// During a drag, seek loosely (fast keyframe seeks); `endScrub` lands exactly.
    func scrub(to seconds: Double) {
        currentTime = seconds
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrub() {
        let target = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                if self.wasPlayingBeforeScrub { self.player.play() }
            }
        }
    }

    func teardown() {
        loopTask?.cancel()
        stopPlayback()
        access = nil
    }

    private func stopPlayback() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        isPlaying = false
    }
}
