import AVFoundation
import Foundation

enum AppError: LocalizedError, Equatable {
    case notAVideoFile(String)
    case fileUnavailable
    case accessDenied
    case unsupportedContainer(String)
    case unsupportedCodec(String)
    case noVideoTrack
    case notPlayable
    case corruptedMedia(String)
    case alreadyInLibrary
    case bookmarkFailed

    var errorDescription: String? {
        switch self {
        case .notAVideoFile(let ext):
            ext.isEmpty ? "This file isn't a video." : "“.\(ext)” files aren't videos."
        case .fileUnavailable:
            "The file can't be found. It may have been moved, renamed, or is on a disconnected drive."
        case .accessDenied:
            "Lumen doesn't have permission to read this file."
        case .unsupportedContainer(let ext):
            "macOS can't open “.\(ext)” video containers."
        case .unsupportedCodec(let codec):
            "This video uses \(codec), which this Mac can't decode."
        case .noVideoTrack:
            "This file doesn't contain a video track."
        case .notPlayable:
            "macOS reports that this video can't be played."
        case .corruptedMedia(let detail):
            "The video couldn't be read. \(detail)"
        case .alreadyInLibrary:
            "This video is already in your library."
        case .bookmarkFailed:
            "Lumen couldn't save permission to reopen this file later."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unsupportedContainer(let ext) where ["mkv", "webm"].contains(ext.lowercased()):
            "AVFoundation has no \(ext.uppercased()) demuxer. If the video inside is H.264 or HEVC, remux it losslessly to MP4 (e.g. `ffmpeg -i input.\(ext) -c copy output.mp4`); otherwise convert it with HandBrake."
        case .unsupportedContainer, .unsupportedCodec:
            "Convert the video to HEVC or H.264 in an MP4 or MOV file (HandBrake, Compressor, or ffmpeg)."
        case .fileUnavailable:
            "Reconnect the drive or use “Locate File…” to point Lumen at the file’s new location."
        case .accessDenied:
            "Import the file again using the Import button or drag and drop."
        case .corruptedMedia:
            "Try re-exporting or re-downloading the video."
        default:
            nil
        }
    }

    /// Translate AVFoundation / Cocoa errors into a user-meaningful case.
    static func classify(_ error: Error, fileExtension ext: String) -> AppError {
        if let appError = error as? AppError { return appError }
        if let avError = error as? AVError {
            switch avError.code {
            case .fileFormatNotRecognized:
                return .unsupportedContainer(ext.isEmpty ? "unknown" : ext)
            case .decoderNotFound, .decoderTemporarilyUnavailable:
                return .unsupportedCodec("a codec")
            case .contentIsNotAuthorized, .contentIsProtected:
                return .notPlayable
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError: return .accessDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .fileUnavailable
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) {
            return .accessDenied
        }
        return .corruptedMedia(ns.localizedDescription)
    }
}
