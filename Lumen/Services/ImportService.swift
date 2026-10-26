import Foundation
import UniformTypeIdentifiers

/// Validates a user-selected file and turns it into a library item:
/// reachability → type check → decode probe → bookmark → thumbnail.
/// The video is never read into memory; AVFoundation streams from disk.
struct ImportService: Sendable {
    let probe: any MediaProbe
    let thumbnails: ThumbnailService

    /// Types offered in the open panel. WebM/MKV are included on purpose so the
    /// user gets a clear explanation instead of a greyed-out file.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .gif]
        for ext in ["m4v", "webm", "mkv", "avi"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    func importVideo(at url: URL, replacing existing: Wallpaper? = nil) async throws -> Wallpaper {
        let access = ScopedFileAccess(url: url)
        defer { withExtendedLifetime(access) {} }

        // 1. The file must exist and be a regular file.
        do {
            guard try url.checkResourceIsReachable() else { throw AppError.fileUnavailable }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.classify(error, fileExtension: url.pathExtension)
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .isReadableKey])
        if values?.isRegularFile == false { throw AppError.notAVideoFile(url.pathExtension) }
        if values?.isReadable == false { throw AppError.accessDenied }

        // 2. Cheap type check by UTI. Unknown types still go to the probe,
        //    because the extension is not a reliable indicator of the contents.
        if let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension),
           !type.conforms(to: .audiovisualContent),
           type.conforms(to: .image) || type.conforms(to: .text) || type.conforms(to: .audio) {
            throw AppError.notAVideoFile(url.pathExtension)
        }

        // 3. Ask the decoder what it can actually do with this file.
        let metadata = try await probe.probe(url: url)

        // 4. Persistable permission to reopen the file after relaunch.
        let bookmark = try BookmarkService.makeBookmark(for: url)

        let id = existing?.id ?? UUID()

        // 5. Thumbnail is best-effort; a failure here must not fail the import.
        var thumbnailName: String?
        do {
            thumbnailName = try await thumbnails.generateThumbnail(for: url, id: id, duration: metadata.duration)
        } catch {
            Log.warning("Thumbnail generation failed: \(error.localizedDescription)", category: "import")
        }

        var wallpaper = Wallpaper(
            id: id,
            title: existing?.title ?? url.deletingPathExtension().lastPathComponent,
            originalPath: url.path,
            bookmark: bookmark,
            metadata: metadata,
            dateAdded: existing?.dateAdded ?? Date(),
            thumbnailFileName: thumbnailName ?? existing?.thumbnailFileName,
            availability: .available,
            lastError: nil,
            soundtracks: existing?.soundtracks ?? []
        )
        if let existing { wallpaper.carryOverCustomizations(from: existing) }
        return wallpaper
    }
}
