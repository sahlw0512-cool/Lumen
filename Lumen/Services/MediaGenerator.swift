import AVFoundation
import CoreImage
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns non-video sources (image slideshows, GIFs) into ordinary video files
/// in Lumen's own folder, so every wallpaper feature works on them unchanged.
/// Rendering runs off the main thread on the GPU through Core Image.
enum MediaGenerator {
    struct SlideshowOptions: Sendable {
        var secondsPerImage: Double = 8
        var transition: Double = 1.5
        /// Slow pan and zoom ("Ken Burns").
        var motion = true
        var size = CGSize(width: 2560, height: 1440)
        var frameRate: Int32 = 30
    }

    enum GenerationError: LocalizedError {
        case noImages, writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noImages: "None of the selected images could be read."
            case .writerFailed(let detail): "Couldn't write the video: \(detail)"
            }
        }
    }

    // MARK: Slideshow

    /// Renders `images` into a seamlessly looping video. The last image
    /// crossfades into the first, so the loop point is invisible.
    static func makeSlideshow(from images: [URL], options: SlideshowOptions,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let size = evenSize(options.size)
        let longest = max(size.width, size.height) * (options.motion ? 1.25 : 1.0)
        let frames: [CIImage] = images.compactMap { url in
            let access = ScopedFileAccess(url: url)
            defer { withExtendedLifetime(access) {} }
            guard let image = downsample(url, maxPixel: longest) else { return nil }
            return CIImage(cgImage: image)
        }
        guard !frames.isEmpty else { throw GenerationError.noImages }

        let perImage = max(options.secondsPerImage, options.transition + 0.5)
        let transition = frames.count > 1 ? options.transition : 0
        let total = perImage * Double(frames.count)
        let fps = Double(options.frameRate)
        let frameCount = Int((total * fps).rounded())
        let canvas = CGRect(origin: .zero, size: size)

        return try await writeVideo(size: size, frameRate: options.frameRate, frameCount: frameCount, progress: progress) { index in
            let t = Double(index) / fps
            let current = min(Int(t / perImage), frames.count - 1)
            let local = t - Double(current) * perImage
            var image = place(frames[current], in: canvas, progress: (local + transition) / (perImage + transition),
                              index: current, motion: options.motion)
            if transition > 0, local > perImage - transition {
                let next = (current + 1) % frames.count
                let alpha = (local - (perImage - transition)) / transition
                let incoming = place(frames[next], in: canvas, progress: (local - perImage + transition) / (perImage + transition),
                                     index: next, motion: options.motion)
                image = fade(incoming, alpha: alpha).composited(over: image)
            }
            return image.cropped(to: canvas)
        }
    }

    /// Fills the canvas with the image, drifting and zooming over `progress` 0...1.
    private static func place(_ image: CIImage, in canvas: CGRect, progress: Double, index: Int, motion: Bool) -> CIImage {
        let extent = image.extent
        let fill = max(canvas.width / extent.width, canvas.height / extent.height)
        let p = min(max(progress, 0), 1)
        let eased = p * p * (3 - 2 * p)
        let zoom = motion ? (index.isMultiple(of: 2) ? 1.0 + 0.12 * eased : 1.12 - 0.12 * eased) : 1.0
        let scale = fill * zoom
        let width = extent.width * scale
        let height = extent.height * scale
        // Alternate drift directions so consecutive images don't move the same way.
        let directions: [(Double, Double)] = [(1, 0.4), (-1, 0.3), (0.5, -1), (-0.6, -0.5)]
        let direction = directions[index % directions.count]
        let travelX = motion ? (width - canvas.width) / 2 * (eased * 2 - 1) * direction.0 : 0
        let travelY = motion ? (height - canvas.height) / 2 * (eased * 2 - 1) * direction.1 : 0
        let x = canvas.midX - width / 2 + travelX
        let y = canvas.midY - height / 2 + travelY
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private static func fade(_ image: CIImage, alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(alpha, 0), 1))])
    }

    // MARK: GIF

    static func isGIF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .gif) == true
    }

    /// Converts an animated GIF to a looping video, keeping each frame's timing.
    static func makeVideo(fromGIF url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let access = ScopedFileAccess(url: url)
        defer { withExtendedLifetime(access) {} }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw GenerationError.noImages }
        let count = CGImageSourceGetCount(source)
        var frames: [(image: CIImage, duration: Double)] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            frames.append((CIImage(cgImage: image), delay < 0.02 ? 0.1 : delay))
        }
        guard let first = frames.first else { throw GenerationError.noImages }

        var size = first.image.extent.size
        let maxSide: CGFloat = 1920
        if max(size.width, size.height) > maxSide {
            let scale = maxSide / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        // Tiny GIFs are upscaled 2× so they don't look mushy when filled.
        if max(size.width, size.height) < 480 { size = CGSize(width: size.width * 2, height: size.height * 2) }
        size = evenSize(size)
        let canvas = CGRect(origin: .zero, size: size)

        let fps: Int32 = 30
        let total = frames.reduce(0) { $0 + $1.duration }
        let frameCount = max(Int((total * Double(fps)).rounded()), 1)
        var starts: [Double] = []
        var elapsed = 0.0
        for frame in frames {
            starts.append(elapsed)
            elapsed += frame.duration
        }

        let outputSize = size
        let frameStarts = starts
        let images = frames.map(\.image)
        return try await writeVideo(size: outputSize, frameRate: fps, frameCount: frameCount, progress: progress) { index in
            let t = Double(index) / Double(fps)
            let image = images[frameStarts.lastIndex { $0 <= t } ?? 0]
            let scale = min(outputSize.width / image.extent.width, outputSize.height / image.extent.height)
            return image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .composited(over: CIImage(color: .black).cropped(to: canvas))
                .cropped(to: canvas)
        }
    }

    // MARK: Writing

    private static func writeVideo(size: CGSize, frameRate: Int32, frameCount: Int,
                                   progress: @escaping @Sendable (Double) -> Void,
                                   frame: @escaping @Sendable (Int) -> CIImage) async throws -> URL {
        let output = AppPaths.generated.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let codec: AVVideoCodecType = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) ? .hevc : .h264
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 4)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw GenerationError.writerFailed("unsupported settings") }
        writer.add(input)
        guard writer.startWriting() else { throw GenerationError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for index in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw GenerationError.writerFailed("no buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw GenerationError.writerFailed("no pixel buffer") }
            context.render(frame(index), to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate))
            if index % 15 == 0 { progress(Double(index) / Double(frameCount)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw GenerationError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        progress(1)
        return output
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    private static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Photos

/// A video from the Photos picker, copied into Lumen's folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = AppPaths.generated.appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum LivePhotoExtractor {
    /// Writes the motion part of a Live Photo to Lumen's folder.
    static func pairedVideo(of livePhoto: PHLivePhoto) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
            throw MediaGenerator.GenerationError.noImages
        }
        let destination = AppPaths.generated.appendingPathComponent("\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: video, toFile: destination, options: options)
        return destination
    }
}
