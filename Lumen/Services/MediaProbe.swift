import AVFoundation
import CoreMedia
import UniformTypeIdentifiers
import VideoToolbox

/// Inspects a media file and reports what the playback stack can do with it.
///
/// This is the extension point for additional decoders: a future
/// FFmpeg/libav-backed probe (paired with a matching renderer) can conform to
/// this protocol without touching the import pipeline or the UI.
protocol MediaProbe: Sendable {
    func probe(url: URL) async throws -> VideoMetadata
}

/// Probe backed by AVFoundation, which decodes through VideoToolbox (hardware
/// decode for H.264, HEVC, ProRes, and AV1 on M3+/A17 Pro-class hardware).
struct AVFoundationMediaProbe: MediaProbe {
    func probe(url: URL) async throws -> VideoMetadata {
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            return try await inspect(asset: asset, url: url)
        } catch {
            throw AppError.classify(error, fileExtension: ext)
        }
    }

    private func inspect(asset: AVURLAsset, url: URL) async throws -> VideoMetadata {
        let (isPlayable, assetDuration) = try await asset.load(.isPlayable, .duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw AppError.noVideoTrack }

        let (naturalSize, transform, nominalFrameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let (formats, dataRate, characteristics) = try await track.load(.formatDescriptions, .estimatedDataRate, .mediaCharacteristics)
        let (trackPlayable, minFrameDuration, timeRange) = try await track.load(.isPlayable, .minFrameDuration, .timeRange)

        // Codec identification and hardware support.
        var fourCC = ""
        var hardware = false
        var primaries: String?
        var transfer: String?
        if let format = formats.first {
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            fourCC = VideoMetadata.string(fromFourCC: subtype)
            hardware = VTIsHardwareDecodeSupported(CMVideoCodecType(subtype))
            primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let codecName = VideoMetadata.codecName(forFourCC: fourCC)

        guard isPlayable, trackPlayable else {
            // The container opened but the codec can't be decoded on this Mac (e.g. VP9 in MOV).
            throw fourCC.isEmpty ? AppError.notPlayable : AppError.unsupportedCodec(codecName)
        }

        // Dimensions after rotation.
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = Int(abs(rotated.width).rounded())
        let height = Int(abs(rotated.height).rounded())
        guard width > 0, height > 0 else {
            throw AppError.corruptedMedia("The video track reports no picture size.")
        }

        // Duration: fall back to the track's range when the container omits it.
        var duration = assetDuration.isNumeric ? assetDuration.seconds : 0
        if duration <= 0, timeRange.duration.isNumeric { duration = timeRange.duration.seconds }
        if !duration.isFinite { duration = 0 }

        // Frame rate: nominal is an average; minFrameDuration reveals the peak rate,
        // which differs for variable-frame-rate (e.g. iPhone) recordings.
        let nominal: Double? = nominalFrameRate > 0 ? Double(nominalFrameRate) : nil
        var peak: Double?
        if minFrameDuration.isNumeric, minFrameDuration.seconds > 0 { peak = 1 / minFrameDuration.seconds }
        var isVFR = false
        if let nominal, let peak { isVFR = abs(peak - nominal) / nominal > 0.05 }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        let isHDR = characteristics.contains(.containsHDRVideo)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])

        return VideoMetadata(
            duration: duration,
            pixelWidth: width,
            pixelHeight: height,
            frameRate: nominal ?? peak,
            isVariableFrameRate: isVFR,
            codecName: codecName,
            codecFourCC: fourCC,
            isHardwareDecodable: hardware,
            hasAudio: !audioTracks.isEmpty,
            isHDR: isHDR,
            colorPrimaries: primaries,
            transferFunction: transfer,
            estimatedBitrate: dataRate > 0 ? Double(dataRate) : nil,
            fileSize: values?.fileSize.map { Int64($0) },
            containerType: values?.contentType?.localizedDescription
        )
    }
}
