import XCTest
@testable import Lumen

final class PlaybackPolicyTests: XCTestCase {
    func testPlaysWhenNothingBlocks() {
        XCTAssertNil(PlaybackPolicy.pauseReason(for: PlaybackConditions(), settings: AppSettings()))
    }

    func testSecurityStatesAlwaysPauseRegardlessOfSettings() {
        var settings = AppSettings()
        settings.pauseWhenDisplaySleeps = false
        settings.pauseOnBattery = false
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: PlaybackConditions(screenLocked: true), settings: settings), .screenLocked)
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: PlaybackConditions(screenSaverRunning: true), settings: settings), .screenSaver)
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: PlaybackConditions(sessionActive: false), settings: settings), .sessionInactive)
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: PlaybackConditions(systemAsleep: true), settings: settings), .systemAsleep)
    }

    func testOptionalConditionsRespectSettings() {
        var settings = AppSettings()
        settings.pauseOnBattery = false
        XCTAssertNil(PlaybackPolicy.pauseReason(for: PlaybackConditions(onBattery: true), settings: settings))
        settings.pauseOnBattery = true
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: PlaybackConditions(onBattery: true), settings: settings), .onBattery)

        settings.pauseWhenFullscreen = false
        XCTAssertNil(PlaybackPolicy.pauseReason(for: PlaybackConditions(fullscreenOnDisplay: true), settings: settings))
        settings.pauseWhenOccluded = false
        XCTAssertNil(PlaybackPolicy.pauseReason(for: PlaybackConditions(surfaceVisible: false), settings: settings))
    }

    func testUserPauseTakesPrecedence() {
        let conditions = PlaybackConditions(userPaused: true, screenLocked: true, onBattery: true)
        XCTAssertEqual(PlaybackPolicy.pauseReason(for: conditions, settings: AppSettings()), .userPaused)
    }
}

final class VideoMetadataTests: XCTestCase {
    private func metadata(_ width: Int, _ height: Int) -> VideoMetadata {
        VideoMetadata(duration: 10, pixelWidth: width, pixelHeight: height, frameRate: 30, isVariableFrameRate: false,
                      codecName: "HEVC", codecFourCC: "hvc1", isHardwareDecodable: true, hasAudio: false, isHDR: false,
                      colorPrimaries: nil, transferFunction: nil, estimatedBitrate: nil, fileSize: nil, containerType: nil)
    }

    func testAspectLabels() {
        XCTAssertEqual(metadata(3840, 2160).aspectLabel, "16:9")
        XCTAssertEqual(metadata(2560, 1600).aspectLabel, "16:10")
        XCTAssertEqual(metadata(3440, 1440).aspectLabel, "21:9")
        XCTAssertEqual(metadata(5120, 1440).aspectLabel, "32:9")
        XCTAssertEqual(metadata(1080, 1920).aspectLabel, "9:16")
    }

    func testAspectClasses() {
        XCTAssertEqual(metadata(1080, 1920).aspectClass, .portrait)
        XCTAssertEqual(metadata(1920, 1080).aspectClass, .landscape)
        XCTAssertEqual(metadata(3440, 1440).aspectClass, .ultrawide)
        XCTAssertEqual(metadata(1000, 1000).aspectClass, .square)
    }

    func testResolutionLabels() {
        XCTAssertEqual(metadata(3840, 2160).resolutionLabel, "4K")
        XCTAssertEqual(metadata(1920, 1080).resolutionLabel, "1080p")
        XCTAssertEqual(metadata(5120, 2880).resolutionLabel, "5K")
        XCTAssertEqual(metadata(1080, 1920).resolutionLabel, "1080p")
    }

    func testFourCCDecoding() {
        XCTAssertEqual(VideoMetadata.string(fromFourCC: 0x6876_6331), "hvc1")
        XCTAssertEqual(VideoMetadata.codecName(forFourCC: "hvc1"), "HEVC")
        XCTAssertEqual(VideoMetadata.codecName(forFourCC: "avc1"), "H.264")
    }
}

final class SettingsCodingTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() throws {
        let json = #"{"pauseOnBattery": true, "idleMinutes": 9999}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.pauseOnBattery)
        XCTAssertEqual(settings.idleMinutes, 240, "values are clamped")
        XCTAssertEqual(settings.defaultScaling, .fill)
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.loopMode = .playOnce
        settings.appearance = .light
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testDockAndMenuBarCannotBothBeHidden() {
        var settings = AppSettings()
        settings.showInDock = false
        settings.showMenuBarItem = false
        settings.sanitize()
        XCTAssertTrue(settings.showMenuBarItem)
    }
}

final class SurfaceLayoutTests: XCTestCase {
    private let screen = CGSize(width: 1600, height: 1000)

    func testFillCoversAndCenters() {
        let layout = SurfaceLayout(videoSize: CGSize(width: 1920, height: 1080), scaling: .fill)
        let frame = layout.videoFrame(in: screen)
        XCTAssertEqual(frame.height, 1000, accuracy: 0.01)
        XCTAssertEqual(frame.width, 1000 * 1920 / 1080, accuracy: 0.01)
        XCTAssertEqual(frame.midX, 800, accuracy: 0.01)
        XCTAssertEqual(frame.midY, 500, accuracy: 0.01)
    }

    func testFitLetterboxes() {
        let frame = SurfaceLayout(videoSize: CGSize(width: 1920, height: 1080), scaling: .fit).videoFrame(in: screen)
        XCTAssertEqual(frame.width, 1600, accuracy: 0.01)
        XCTAssertEqual(frame.height, 900, accuracy: 0.01)
    }

    func testPanToEdgeAlignsEdges() {
        var layout = SurfaceLayout(videoSize: CGSize(width: 1920, height: 1080), scaling: .fill)
        layout.position.offsetX = 1
        XCTAssertEqual(layout.videoFrame(in: screen).maxX, 1600, accuracy: 0.01, "right edge of video meets right edge of screen")
        layout.position.offsetX = -1
        XCTAssertEqual(layout.videoFrame(in: screen).minX, 0, accuracy: 0.01)

        layout.scaling = .fit
        layout.position = ContentPosition(zoom: 1, offsetX: 0, offsetY: 1)
        XCTAssertEqual(layout.videoFrame(in: screen).maxY, 1000, accuracy: 0.01, "letterboxed video pushed to the top")
    }

    func testZoomEnlarges() {
        var layout = SurfaceLayout(videoSize: CGSize(width: 1600, height: 1000), scaling: .fill)
        layout.position.zoom = 2
        let frame = layout.videoFrame(in: screen)
        XCTAssertEqual(frame.width, 3200, accuracy: 0.01)
        XCTAssertEqual(frame.midX, 800, accuracy: 0.01)
    }

    func testSpanSplitsVideoAcrossDisplays() {
        // Two 1600×1000 displays side by side.
        let left = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let right = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        let union = left.union(right)
        let video = CGSize(width: 3200, height: 1000)

        let leftFrame = SurfaceLayout(canvas: SurfaceLayout.spanCanvas(union: union, display: left),
                                      videoSize: video, scaling: .fill).videoFrame(in: left.size)
        let rightFrame = SurfaceLayout(canvas: SurfaceLayout.spanCanvas(union: union, display: right),
                                       videoSize: video, scaling: .fill).videoFrame(in: right.size)
        XCTAssertEqual(leftFrame, CGRect(x: 0, y: 0, width: 3200, height: 1000))
        XCTAssertEqual(rightFrame, CGRect(x: -1600, y: 0, width: 3200, height: 1000))
    }
}

final class FrameRateCapTests: XCTestCase {
    func testNoCapByDefault() {
        XCTAssertNil(PlaybackPolicy.frameRateCap(for: PlaybackConditions(), settings: AppSettings()))
    }

    func testLowestApplicableCapWins() {
        var settings = AppSettings()
        settings.maxFrameRate = .fps60
        settings.lowerFrameRateOnBattery = true
        settings.batteryFrameRate = .fps24
        XCTAssertEqual(PlaybackPolicy.frameRateCap(for: PlaybackConditions(), settings: settings), 60)
        XCTAssertEqual(PlaybackPolicy.frameRateCap(for: PlaybackConditions(onBattery: true), settings: settings), 24)

        settings.lowerFrameRateWhenIdle = true
        XCTAssertEqual(PlaybackPolicy.frameRateCap(for: PlaybackConditions(onBattery: true, userIdle: true), settings: settings),
                       PlaybackPolicy.reducedFrameRate)
    }

    func testSettingsWithoutNewKeysDecodeToDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"audioVolume": 0.3}"#.utf8))
        XCTAssertEqual(settings.maxFrameRate, .native)
        XCTAssertEqual(settings.effects, WallpaperEffects())
        XCTAssertEqual(settings.audioVolume, 0.3)
    }

    func testOldLibraryDocumentsStillDecode() throws {
        let json = #"{"version": 1, "wallpapers": [], "assignments": {"A": {"displayName": "Studio Display"}}}"#
        let document = try JSONDecoder().decode(LibraryDocument.self, from: Data(json.utf8))
        XCTAssertNil(document.span)
        XCTAssertNil(document.assignments["A"]?.position)
    }
}

final class PlaylistTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testAdvancesInOrderAndWraps() {
        let playlist = Playlist(name: "P", wallpaperIDs: [a, b, c])
        let all: Set = [a, b, c]
        XCTAssertEqual(playlist.next(after: nil, available: all), a)
        XCTAssertEqual(playlist.next(after: a, available: all), b)
        XCTAssertEqual(playlist.next(after: c, available: all), a)
    }

    func testSkipsMissingWallpapers() {
        let playlist = Playlist(name: "P", wallpaperIDs: [a, b, c])
        XCTAssertEqual(playlist.next(after: a, available: [a, c]), c)
        XCTAssertNil(playlist.next(after: a, available: []))
    }

    func testShuffleNeverRepeatsCurrent() {
        var playlist = Playlist(name: "P", wallpaperIDs: [a, b])
        playlist.shuffle = true
        for roll in stride(from: 0.0, to: 1.0, by: 0.1) {
            XCTAssertEqual(playlist.next(after: a, available: [a, b], random: { roll }), b)
        }
    }
}

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: hour, minute: minute))!
    }

    func testActiveEntryIsLatestPassedTrigger() {
        let morning = ScheduleEntry(trigger: .time(minutes: 8 * 60), target: .wallpaper(UUID()))
        let evening = ScheduleEntry(trigger: .time(minutes: 20 * 60), target: .wallpaper(UUID()))
        let schedule = WallpaperSchedule(isEnabled: true, entries: [evening, morning])
        XCTAssertEqual(schedule.activeEntry(at: date(12), calendar: calendar, solar: { _ in nil })?.id, morning.id)
        XCTAssertEqual(schedule.activeEntry(at: date(21), calendar: calendar, solar: { _ in nil })?.id, evening.id)
        XCTAssertEqual(schedule.activeEntry(at: date(6), calendar: calendar, solar: { _ in nil })?.id, evening.id,
                       "before the first trigger, last night's entry is still in effect")
    }

    func testNextChange() {
        let schedule = WallpaperSchedule(isEnabled: true, entries: [
            ScheduleEntry(trigger: .time(minutes: 8 * 60), target: .wallpaper(UUID())),
            ScheduleEntry(trigger: .time(minutes: 20 * 60), target: .wallpaper(UUID())),
        ])
        XCTAssertEqual(schedule.nextChange(after: date(12), calendar: calendar, solar: { _ in nil }), date(20))
        let tomorrow8 = calendar.date(byAdding: .day, value: 1, to: date(8))!
        XCTAssertEqual(schedule.nextChange(after: date(21), calendar: calendar, solar: { _ in nil }), tomorrow8)
    }

    func testSolarTimesForNewYorkSolstice() throws {
        let times = try XCTUnwrap(SolarCalculator.times(on: date(12), at: Coordinates(latitude: 40.71, longitude: -74.01), calendar: calendar))
        let sunrise = calendar.dateComponents([.hour, .minute], from: times.sunrise)
        let sunset = calendar.dateComponents([.hour, .minute], from: times.sunset)
        // Published: sunrise 5:25, sunset 20:31 EDT.
        XCTAssertEqual(Double(sunrise.hour! * 60 + sunrise.minute!), 5 * 60 + 25, accuracy: 3)
        XCTAssertEqual(Double(sunset.hour! * 60 + sunset.minute!), 20 * 60 + 31, accuracy: 3)
    }

    func testPolarDayHasNoSunset() {
        XCTAssertNil(SolarCalculator.times(on: date(12), at: Coordinates(latitude: 78.2, longitude: 15.6), calendar: calendar))
    }
}

final class WallpaperCustomizationTests: XCTestCase {
    func testOldLibraryItemsDecodeWithDefaults() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Waves", "originalPath": "/tmp/waves.mov",
         "metadata": {"duration": 20, "pixelWidth": 1920, "pixelHeight": 1080, "isVariableFrameRate": false,
                      "codecName": "HEVC", "codecFourCC": "hvc1", "isHardwareDecodable": true, "hasAudio": false, "isHDR": false},
         "dateAdded": 0, "availability": "available"}
        """
        let wallpaper = try JSONDecoder().decode(Wallpaper.self, from: Data(json.utf8))
        XCTAssertFalse(wallpaper.isFavorite)
        XCTAssertEqual(wallpaper.tags, [])
        XCTAssertNil(wallpaper.effects)
        XCTAssertNil(wallpaper.loopRange)
        XCTAssertEqual(wallpaper.loopCrossfade, 0)
    }

    func testLoopRangeIsClamped() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "title": "Waves", "originalPath": "/tmp/waves.mov",
         "metadata": {"duration": 20, "pixelWidth": 1920, "pixelHeight": 1080, "isVariableFrameRate": false,
                      "codecName": "HEVC", "codecFourCC": "hvc1", "isHardwareDecodable": true, "hasAudio": false, "isHDR": false},
         "dateAdded": 0, "availability": "available", "trimStart": 5, "trimEnd": 99}
        """
        let wallpaper = try JSONDecoder().decode(Wallpaper.self, from: Data(json.utf8))
        XCTAssertEqual(wallpaper.loopRange, 5...20)
    }

    func testPresetKeepsGlobalClock() {
        var global = WallpaperEffects()
        global.clock.enabled = true
        let focus = EffectPreset.builtIn.first { $0.name == "Focus" }!
        let applied = focus.effects.adjustments(appliedTo: global)
        XCTAssertTrue(applied.clock.enabled)
        XCTAssertEqual(applied.blur, focus.effects.blur)
    }
}

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

final class MediaPipelineTests: XCTestCase {
    private func makeImage(color: CGColor, size: CGSize = CGSize(width: 640, height: 360)) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testSlideshowRendersLoopableVideoAndCrossfadeComposes() async throws {
        let images = try [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
            .map { try writePNG(makeImage(color: $0)) }
        var options = MediaGenerator.SlideshowOptions()
        options.secondsPerImage = 2
        options.transition = 0.5
        options.size = CGSize(width: 320, height: 180)
        let video = try await MediaGenerator.makeSlideshow(from: images, options: options) { _ in }
        defer { try? FileManager.default.removeItem(at: video) }

        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.1)

        let loop = try await LoopComposer.make(url: video, settings: LoopSettings(range: 0.5...3.5, crossfade: 1))
        let loopDuration = try await loop.asset.load(.duration).seconds
        XCTAssertEqual(loopDuration, 2, accuracy: 0.05, "3 s range minus a 1 s crossfade")
        XCTAssertNotNil(loop.videoComposition)

        let trimmed = try await LoopComposer.make(url: video, settings: LoopSettings(range: 1...3, crossfade: 0))
        XCTAssertNil(trimmed.videoComposition)
        XCTAssertEqual(try XCTUnwrap(trimmed.timeRange).duration.seconds, 2, accuracy: 0.01)
    }

    func testGIFConvertsWithFrameTiming() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for gray in [0.1, 0.5, 0.9] {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary
            CGImageDestinationAddImage(destination, makeImage(color: CGColor(gray: gray, alpha: 1), size: CGSize(width: 200, height: 200)), properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(MediaGenerator.isGIF(url))

        let video = try await MediaGenerator.makeVideo(fromGIF: url) { _ in }
        defer { try? FileManager.default.removeItem(at: video) }
        let asset = AVURLAsset(url: video)
        let gifDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(gifDuration, 1.5, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 400, "small GIFs are upscaled 2×")
    }
}


final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.1.0", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10", newerThan: "1.9.3"))
        XCTAssertTrue(UpdateChecker.isVersion("2", newerThan: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta", newerThan: "1.2.0"))
    }
}
