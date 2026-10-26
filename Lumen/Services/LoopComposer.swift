import AVFoundation

/// How a wallpaper loops: an optional trimmed range and an optional crossfade
/// at the loop point.
struct LoopSettings: Equatable, Sendable {
    var range: ClosedRange<Double>?
    var crossfade: Double = 0

    var isPlain: Bool { range == nil && crossfade <= 0.01 }
}

/// What the player plays for a looping wallpaper.
struct LoopComposition: @unchecked Sendable {
    let asset: AVAsset
    /// Range of `asset` to loop (nil = all of it).
    let timeRange: CMTimeRange?
    /// The crossfade compositing; nil for a plain or trimmed loop.
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

/// Builds seamless loops without re-encoding anything.
///
/// A crossfaded loop of the range [s, e] with fade length X is a composition
/// of length D = (e − s) − X:
/// - track A plays the source from s + X to e over [0, D]
/// - track B plays the source from s to s + X over [D − X, D], fading in over A
///
/// When the composition restarts at 0, track A resumes at s + X: exactly where
/// track B's fade-in ended. The seam is hidden inside the crossfade.
enum LoopComposer {
    static func make(url: URL, settings: LoopSettings) async throws -> LoopComposition {
        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration).seconds
        let start = min(max(settings.range?.lowerBound ?? 0, 0), max(duration - 0.5, 0))
        let end = min(settings.range?.upperBound ?? duration, duration)
        let length = end - start
        let fade = min(settings.crossfade, length / 3)

        guard fade > 0.05, let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            let range = CMTimeRange(start: time(start), end: time(end))
            return LoopComposition(asset: source, timeRange: settings.range == nil ? nil : range,
                                   videoComposition: nil, audioMix: nil)
        }

        let composition = AVMutableComposition()
        let total = length - fade
        let fadeStart = time(total - fade)
        let fadeRange = CMTimeRange(start: fadeStart, duration: time(fade))
        let bodyRange = CMTimeRange(start: time(start + fade), end: time(end))
        let headRange = CMTimeRange(start: time(start), duration: time(fade))

        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.notPlayable
        }
        try videoA.insertTimeRange(bodyRange, of: sourceVideo, at: .zero)
        try videoB.insertTimeRange(headRange, of: sourceVideo, at: fadeStart)
        let transform = try await sourceVideo.load(.preferredTransform)
        videoA.preferredTransform = transform
        videoB.preferredTransform = transform

        var audioMix: AVMutableAudioMix?
        if let sourceAudio = try await source.loadTracks(withMediaType: .audio).first,
           let audioA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let audioB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioA.insertTimeRange(bodyRange, of: sourceAudio, at: .zero)
            try audioB.insertTimeRange(headRange, of: sourceAudio, at: fadeStart)
            let outgoing = AVMutableAudioMixInputParameters(track: audioA)
            outgoing.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: fadeRange)
            let incoming = AVMutableAudioMixInputParameters(track: audioB)
            incoming.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: fadeRange)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [outgoing, incoming]
            audioMix = mix
        }

        // Start from the asset's own properties (render size, frame rate, color
        // space, HDR) and replace only the instructions.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)

        let body = AVMutableVideoCompositionInstruction()
        body.timeRange = CMTimeRange(start: .zero, end: fadeStart)
        let bodyLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoA)
        bodyLayer.setTransform(transform, at: .zero)
        body.layerInstructions = [bodyLayer]

        let blend = AVMutableVideoCompositionInstruction()
        blend.timeRange = fadeRange
        let incomingLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoB)
        incomingLayer.setTransform(transform, at: fadeStart)
        incomingLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: fadeRange)
        let outgoingLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoA)
        outgoingLayer.setTransform(transform, at: fadeStart)
        blend.layerInstructions = [incomingLayer, outgoingLayer]   // first = topmost

        videoComposition.instructions = [body, blend]
        return LoopComposition(asset: composition, timeRange: nil, videoComposition: videoComposition, audioMix: audioMix)
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
