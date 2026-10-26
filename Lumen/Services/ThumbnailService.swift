import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Generates, stores, and caches still frames. Disk images live in
/// Application Support; decoded images live in a bounded `NSCache`
/// (thread-safe, evicted automatically under memory pressure).
final class ThumbnailService: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    let directory: URL
    private let cache = NSCache<NSString, Box>()

    init(directory: URL = AppPaths.thumbnails) {
        self.directory = directory
        cache.countLimit = 150
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func fileExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(named: name).path)
    }

    /// Returns a decoded thumbnail, reading from disk off the main thread on a cache miss.
    func image(named name: String) async -> CGImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit.image }
        let url = fileURL(named: name)
        let decoded = await Task.detached(priority: .utility) { () -> Box? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            return Box(image)
        }.value
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: name as NSString, cost: decoded.image.bytesPerRow * decoded.image.height)
        return decoded.image
    }

    /// Extracts a representative frame and writes it as a JPEG. Returns the file name.
    func generateThumbnail(for videoURL: URL, id: UUID, duration: Double) async throws -> String {
        let time = duration > 2 ? min(duration * 0.15, 5) : 0
        let image = try await frame(from: videoURL, atSeconds: time, maximumSize: CGSize(width: 960, height: 960))
        let name = "\(id.uuidString).jpg"
        try Self.writeJPEG(image, to: fileURL(named: name), quality: 0.85)
        cache.removeObject(forKey: name as NSString)
        return name
    }

    /// Decodes a single frame using the hardware decoder where available.
    /// `maximumSize` of nil returns the full-resolution frame.
    /// `exact` decodes precisely the requested frame (slower) instead of the nearest keyframe.
    func frame(from videoURL: URL, atSeconds seconds: Double, maximumSize: CGSize?, exact: Bool = false) async throws -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maximumSize { generator.maximumSize = maximumSize }
        let tolerance = exact ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            guard seconds > 0 else { throw error }
            return try await generator.image(at: .zero).image
        }
    }

    func delete(named name: String) {
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: fileURL(named: name))
    }

    func diskUsage() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Removes thumbnails no library item references any more.
    func removeOrphans(keeping names: Set<String>) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where !names.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
