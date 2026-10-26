import AppIntents
import Foundation

// MARK: - Entities

struct WallpaperEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Wallpaper")
    static let defaultQuery = WallpaperQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WallpaperQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WallpaperEntity] {
        await MainActor.run {
            identifiers.compactMap { AppModel.shared.wallpaper(id: $0) }.map { WallpaperEntity(id: $0.id, title: $0.title) }
        }
    }

    func entities(matching string: String) async throws -> [WallpaperEntity] {
        await MainActor.run {
            AppModel.shared.availableWallpapers
                .filter { $0.title.localizedCaseInsensitiveContains(string) }
                .map { WallpaperEntity(id: $0.id, title: $0.title) }
        }
    }

    func suggestedEntities() async throws -> [WallpaperEntity] {
        await MainActor.run { AppModel.shared.availableWallpapers.map { WallpaperEntity(id: $0.id, title: $0.title) } }
    }
}

struct PlaylistEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        await MainActor.run {
            identifiers.compactMap { AppModel.shared.playlist(id: $0) }.map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await MainActor.run { AppModel.shared.playlists.map { PlaylistEntity(id: $0.id, name: $0.name) } }
    }
}

struct EffectPresetEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Effect Preset")
    static let defaultQuery = EffectPresetQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct EffectPresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [EffectPresetEntity] {
        await MainActor.run {
            AppModel.shared.allEffectPresets.filter { identifiers.contains($0.id) }.map { EffectPresetEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [EffectPresetEntity] {
        await MainActor.run { AppModel.shared.allEffectPresets.map { EffectPresetEntity(id: $0.id, name: $0.name) } }
    }
}

// MARK: - Actions

struct SetWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wallpaper"
    static let description = IntentDescription("Shows a wallpaper from your Lumen library on every display.")

    @Parameter(title: "Wallpaper") var wallpaper: WallpaperEntity

    static var parameterSummary: some ParameterSummary { Summary("Set wallpaper to \(\.$wallpaper)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.apply(wallpaper.id)
        return .result()
    }
}

struct NextWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Wallpaper"
    static let description = IntentDescription("Moves to the next wallpaper in the playing playlist, or the library.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.nextWallpaper()
        return .result()
    }
}

struct SetPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Wallpaper"

    @Parameter(title: "Paused", default: true) var paused: Bool

    static var parameterSummary: some ParameterSummary { Summary("Set wallpaper paused to \(\.$paused)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.engine.isUserPaused = paused
        return .result()
    }
}

struct TogglePauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Wallpaper Playback"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.togglePause()
        return .result()
    }
}

struct StartPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"

    @Parameter(title: "Playlist") var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startPlaylist(playlist.id)
        return .result()
    }
}

struct StopPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Playlist"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.stopPlaylist()
        return .result()
    }
}

struct ApplyEffectPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Effect Preset"

    @Parameter(title: "Preset") var preset: EffectPresetEntity

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset) effects") }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let match = AppModel.shared.allEffectPresets.first(where: { $0.id == preset.id }) {
            AppModel.shared.applyEffectPreset(match)
        }
        return .result()
    }
}

// MARK: - Focus filter

/// Lets a Focus (Work, Sleep, …) switch the wallpaper, apply effects, or pause.
/// The system runs it again with empty values when the Focus ends.
struct LumenFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Lumen Wallpaper"
    static let description: IntentDescription? = IntentDescription("Change the wallpaper or its look while this Focus is on.")

    @Parameter(title: "Wallpaper") var wallpaper: WallpaperEntity?
    @Parameter(title: "Effect Preset") var preset: EffectPresetEntity?
    @Parameter(title: "Pause Wallpaper", default: false) var pause: Bool

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let wallpaper { parts.append(wallpaper.title) }
        if let preset { parts.append("\(preset.name) effects") }
        if pause { parts.append("paused") }
        return DisplayRepresentation(title: "Lumen", subtitle: parts.isEmpty ? "No change" : "\(parts.joined(separator: ", "))")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusFilterState.shared.apply(wallpaper: wallpaper?.id, presetID: preset?.id, pause: pause)
        return .result()
    }
}

/// Remembers what was on before a Focus changed things, so ending it restores them.
@MainActor
final class FocusFilterState {
    static let shared = FocusFilterState()
    private var saved: (wallpaper: UUID?, effects: WallpaperEffects, paused: Bool)?

    func apply(wallpaper: UUID?, presetID: UUID?, pause: Bool) {
        let model = AppModel.shared
        let isEnding = wallpaper == nil && presetID == nil && !pause
        if isEnding {
            guard let saved else { return }
            if let previous = saved.wallpaper, previous != model.lastAppliedWallpaperID { model.apply(previous) }
            model.settings.effects = saved.effects
            model.engine.isUserPaused = saved.paused
            self.saved = nil
            return
        }
        if saved == nil {
            saved = (model.lastAppliedWallpaperID, model.settings.effects, model.engine.isUserPaused)
        }
        if let wallpaper { model.apply(wallpaper) }
        if let presetID, let preset = model.allEffectPresets.first(where: { $0.id == presetID }) {
            model.applyEffectPreset(preset)
        }
        model.engine.isUserPaused = pause
    }
}

// MARK: - Shortcuts app

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextWallpaperIntent(), phrases: ["Next wallpaper in \(.applicationName)"],
                    shortTitle: "Next Wallpaper", systemImageName: "forward.fill")
        AppShortcut(intent: TogglePauseIntent(), phrases: ["Pause \(.applicationName)", "Toggle \(.applicationName) wallpaper"],
                    shortTitle: "Pause or Resume", systemImageName: "playpause.fill")
        AppShortcut(intent: SetWallpaperIntent(), phrases: ["Set \(.applicationName) wallpaper"],
                    shortTitle: "Set Wallpaper", systemImageName: "photo.tv")
        AppShortcut(intent: StartPlaylistIntent(), phrases: ["Play a \(.applicationName) playlist"],
                    shortTitle: "Play Playlist", systemImageName: "rectangle.stack.badge.play")
    }
}
