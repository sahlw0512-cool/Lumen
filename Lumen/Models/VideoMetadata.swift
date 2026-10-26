import Foundation

/// Technical facts about an imported video, extracted once at import time.
/// Pixel dimensions are stored *after* applying the track's preferred transform,
/// so a phone video recorded in portrait reports a portrait size.
struct VideoMetadata: Codable, Hashable, Sendable {
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var frameRate: Double?
    var isVariableFrameRate: Bool
    var codecName: String
    var codecFourCC: String
    var isHardwareDecodable: Bool
    var hasAudio: Bool
    var isHDR: Bool
    var colorPrimaries: String?
    var transferFunction: String?
    var estimatedBitrate: Double?
    var fileSize: Int64?
    var containerType: String?

    enum AspectClass: String, Sendable {
        case portrait, square, landscape, ultrawide

        var title: String {
            switch self {
            case .portrait: "Portrait"
            case .square: "Square"
            case .landscape: "Landscape"
            case .ultrawide: "Ultrawide"
            }
        }
    }

    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 16.0 / 9.0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var aspectClass: AspectClass {
        let ratio = aspectRatio
        if ratio < 0.95 { return .portrait }
        if ratio <= 1.05 { return .square }
        if ratio >= 2.1 { return .ultrawide }
        return .landscape
    }

    /// A human-friendly ratio such as "16:9" or "21:9", falling back to "2.39:1".
    var aspectLabel: String {
        let known: [(Int, Int, Double)] = [
            (16, 9, 16.0 / 9.0), (16, 10, 1.6), (4, 3, 4.0 / 3.0), (3, 2, 1.5), (5, 4, 1.25),
            (1, 1, 1.0), (21, 9, 64.0 / 27.0), (32, 9, 32.0 / 9.0), (9, 16, 9.0 / 16.0),
            (10, 16, 0.625), (3, 4, 0.75), (2, 3, 2.0 / 3.0), (4, 5, 0.8),
        ]
        let ratio = aspectRatio
        if let match = known.first(where: { abs($0.2 - ratio) / $0.2 < 0.03 }) {
            return "\(match.0):\(match.1)"
        }
        // 3440×1440 and 2560×1080 monitors are marketed as 21:9 even though they're ~2.37–2.39.
        if ratio > 2.3 && ratio < 2.45 { return "21:9" }
        return ratio >= 1 ? String(format: "%.2f:1", ratio) : String(format: "1:%.2f", 1 / ratio)
    }

    var resolutionLabel: String {
        let long = max(pixelWidth, pixelHeight)
        let short = min(pixelWidth, pixelHeight)
        switch long {
        case 7680...: return "8K"
        case 6016...: return "6K"
        case 5120...: return "5K"
        case 3840...: return "4K"
        case 2560...: return short >= 1440 ? "1440p" : "\(short)p"
        case 1920...: return "1080p"
        case 1280...: return "720p"
        default: return short > 0 ? "\(short)p" : "SD"
        }
    }

    var dimensionsLabel: String { "\(pixelWidth) × \(pixelHeight)" }

    /// Mapping from QuickTime/ISO codec FourCCs to marketing names.
    static func codecName(forFourCC code: String) -> String {
        switch code {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "Dolby Vision (HEVC)"
        case "dvav", "dva1": "Dolby Vision (H.264)"
        case "apch": "ProRes 422 HQ"
        case "apcn": "ProRes 422"
        case "apcs": "ProRes 422 LT"
        case "apco": "ProRes 422 Proxy"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "aprn", "aprh": "ProRes RAW"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "vp08": "VP8"
        case "jpeg", "mjpa", "mjpb": "Motion JPEG"
        case "mp4v": "MPEG-4 Part 2"
        case "mp2v", "mpg2": "MPEG-2"
        default: code.isEmpty ? "Unknown" : code.uppercased()
        }
    }

    static func string(fromFourCC code: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
