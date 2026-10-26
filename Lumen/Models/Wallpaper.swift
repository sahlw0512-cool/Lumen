import Foundation

/// Availability of the original file referenced by a library item.
enum WallpaperAvailability: String, Codable, Hashable, Sendable {
    case available
    case missing
}

/// One item in the user's library. The video itself is never copied: the item
/// references the user's original file through a security-scoped bookmark.
struct Wallpaper: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    /// Last known path, for display only. The bookmark is the source of truth.
    var originalPath: String
    var bookmark: Data?
    var metadata: VideoMetadata
    var dateAdded: Date
    var thumbnailFileName: String?
    var availability: WallpaperAvailability
    /// Last playback/decoding error reported by the engine, if any.
    var lastError: String?
    /// Audio files played in order (and looped) while this wallpaper is on the main display.
    var soundtracks: [Soundtrack] = []
    var isFavorite = false
    var tags: [String] = []
    /// Picture adjustments for this wallpaper only (nil = the global effects).
    var effects: WallpaperEffects?
    /// Loop only this part of the video (seconds; nil = the whole video).
    var trimStart: Double?
    var trimEnd: Double?
    /// Seconds of crossfade at the loop point (0 = a hard cut).
    var loopCrossfade: Double = 0
    /// The frame (seconds) used for the lock screen, login window, and screen saver.
    var posterTime: Double?
    /// The file was created by Lumen (slideshow, GIF, Live Photo) and lives in
    /// Lumen's own folder, so removing the item deletes it.
    var isGenerated = false

    var fileName: String { (originalPath as NSString).lastPathComponent }
    var isAvailable: Bool { availability == .available }
}

extension Wallpaper {
    private enum CodingKeys: String, CodingKey {
        case id, title, originalPath, bookmark, metadata, dateAdded, thumbnailFileName, availability, lastError, soundtracks
        case isFavorite, tags, effects, trimStart, trimEnd, loopCrossfade, posterTime, isGenerated
    }

    /// Libraries saved before soundtracks existed have no `soundtracks` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        metadata = try c.decode(VideoMetadata.self, forKey: .metadata)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        availability = try c.decode(WallpaperAvailability.self, forKey: .availability)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        soundtracks = (try? c.decodeIfPresent([Soundtrack].self, forKey: .soundtracks)) ?? []
        isFavorite = c.value(.isFavorite, or: false)
        tags = c.value(.tags, or: [])
        effects = c.value(.effects, or: nil)
        trimStart = c.value(.trimStart, or: nil)
        trimEnd = c.value(.trimEnd, or: nil)
        loopCrossfade = c.value(.loopCrossfade, or: 0)
        posterTime = c.value(.posterTime, or: nil)
        isGenerated = c.value(.isGenerated, or: false)
    }

    /// The looped range, clamped to the video, or nil for the whole video.
    var loopRange: ClosedRange<Double>? {
        guard trimStart != nil || trimEnd != nil else { return nil }
        let duration = metadata.duration
        let start = min(max(trimStart ?? 0, 0), max(duration - 0.5, 0))
        let end = min(max(trimEnd ?? duration, start + 0.5), duration > 0 ? duration : .greatestFiniteMagnitude)
        return start...end
    }

    /// Keeps the user's choices when a file is relinked or re-imported.
    mutating func carryOverCustomizations(from other: Wallpaper) {
        isFavorite = other.isFavorite
        tags = other.tags
        effects = other.effects
        trimStart = other.trimStart
        trimEnd = other.trimEnd
        loopCrossfade = other.loopCrossfade
        posterTime = other.posterTime
        isGenerated = other.isGenerated
    }
}

/// An audio file attached to a wallpaper, referenced (never copied) by bookmark.
struct Soundtrack: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    /// Last known path, for display only. The bookmark is the source of truth.
    var originalPath: String
    var bookmark: Data?
    var duration: Double?
    /// Optional, set by the user when renaming.
    var artist: String?
}

/// What a display should show.
struct DisplayAssignment: Codable, Hashable, Sendable {
    var wallpaperID: UUID?
    /// nil means "use the default scaling mode from Settings".
    var scaling: ScalingMode?
    /// Last known display name, so disconnected displays can still be listed.
    var displayName: String
    /// nil means centered at natural size.
    var position: ContentPosition?
}

/// On-disk representation of the library (Application Support/…/Library.json).
struct LibraryDocument: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = LibraryDocument.currentVersion
    var wallpapers: [Wallpaper] = []
    /// Keyed by the display's stable UUID string (see `DisplayInfo.id`).
    var assignments: [String: DisplayAssignment] = [:]
    var lastAppliedWallpaperID: UUID?
    /// When set, one video spans every connected display (overrides `assignments`).
    var span: SpanConfiguration?
    /// Display (stable key) that plays wallpaper audio. nil, or a disconnected
    /// display, means the main display.
    var audioDisplayKey: String?
    var playlists: [Playlist]?
    /// The playlist currently rotating, if any.
    var activePlaylistID: UUID?
    var schedule: WallpaperSchedule?
}

struct ImportProgress: Equatable {
    var total: Int
    var completed: Int
    var currentName: String

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

struct ImportFailure: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let message: String
    let suggestion: String?
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAdded, title, duration, resolution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateAdded: "Date Added"
        case .title: "Name"
        case .duration: "Duration"
        case .resolution: "Resolution"
        }
    }
}
