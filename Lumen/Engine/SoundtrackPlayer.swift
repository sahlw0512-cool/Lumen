import AVFoundation

/// Plays a wallpaper's soundtracks back to back and loops the whole playlist.
///
/// Each finished item is re-appended to the end of the queue, so the queue
/// always holds the full playlist and playback never runs dry. Audio-only
/// decoding is cheap; when paused, nothing is decoded.
@MainActor
final class SoundtrackPlayer {
    let urls: [URL]

    private let player = AVQueuePlayer()
    private var fileAccess: [ScopedFileAccess]
    private var endObserver: NSObjectProtocol?
    private var isInvalidated = false

    init(urls: [URL]) {
        self.urls = urls
        fileAccess = urls.map(ScopedFileAccess.init(url:))
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        for url in urls {
            player.insert(AVPlayerItem(url: url), after: nil)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, self.player.items().contains(item),
                      let asset = item.asset as? AVURLAsset else { return }
                self.player.insert(AVPlayerItem(url: asset.url), after: nil)
            }
        }
    }

    func play() {
        guard !isInvalidated, player.timeControlStatus != .playing else { return }
        player.play()
    }

    func pause() {
        guard !isInvalidated else { return }
        player.pause()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    /// Releases decoders and file handles. Safe to call more than once.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.removeAllItems()
        fileAccess.removeAll()
    }
}
