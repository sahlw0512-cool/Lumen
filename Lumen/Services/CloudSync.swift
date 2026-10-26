import Foundation
import Observation

struct SyncedPlaylist: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var fileNames: [String]
    var intervalMinutes: Int
    var shuffle: Bool
}

/// What travels between Macs. Videos never leave the Mac; items are matched by
/// file name, so a wallpaper only lines up where the same file was imported.
struct SyncPayload: Codable, Equatable, Sendable {
    var modified: Date
    var device: String
    var effects: WallpaperEffects
    var effectPresets: [EffectPreset]
    var maxFrameRate: FrameRateCap
    var favorites: [String]
    var tags: [String: [String]]
    var playlists: [SyncedPlaylist]
}

/// Syncs settings, effect presets, favorites, tags, and playlists through the
/// iCloud key-value store (1 MB, free, no CloudKit schema).
///
/// Requires the "iCloud › Key-value storage" capability on the app target;
/// without it the store reports itself unavailable and this stays idle.
@MainActor
@Observable
final class CloudSync {
    enum Status: Equatable {
        case off, unavailable, idle, synced(Date)
    }

    private(set) var status: Status = .off

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private let store = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private let key = "lumen.sync.v1"
    @ObservationIgnored private let device = Host.current().localizedName ?? "Mac"

    init(model: AppModel) {
        self.model = model
    }

    func setEnabled(_ enabled: Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pushTask?.cancel()
        guard enabled else {
            status = .off
            return
        }
        guard store.synchronize() else {
            status = .unavailable
            Log.warning("iCloud sync unavailable: the app needs the iCloud key-value storage capability and an iCloud account", category: "sync")
            return
        }
        status = .idle
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        pull()
        localChange()
    }

    /// Something syncable changed here; push after a short pause to batch edits.
    func localChange() {
        guard status != .off, status != .unavailable, !isApplyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    private func makePayload() -> SyncPayload {
        let wallpapers = model.wallpapers
        let names = Dictionary(wallpapers.map { ($0.id, $0.fileName) }, uniquingKeysWith: { first, _ in first })
        return SyncPayload(
            modified: Date(),
            device: device,
            effects: model.settings.effects,
            effectPresets: model.settings.effectPresets,
            maxFrameRate: model.settings.maxFrameRate,
            favorites: wallpapers.filter(\.isFavorite).map(\.fileName),
            tags: Dictionary(wallpapers.filter { !$0.tags.isEmpty }.map { ($0.fileName, $0.tags) }, uniquingKeysWith: { first, _ in first }),
            playlists: model.playlists.map {
                SyncedPlaylist(id: $0.id, name: $0.name, fileNames: $0.wallpaperIDs.compactMap { names[$0] },
                               intervalMinutes: $0.intervalMinutes, shuffle: $0.shuffle)
            }
        )
    }

    private func push() {
        guard let data = try? JSONEncoder().encode(makePayload()) else { return }
        store.set(data, forKey: key)
        store.synchronize()
        status = .synced(Date())
    }

    private func pull() {
        guard let data = store.data(forKey: key),
              let payload = try? JSONDecoder().decode(SyncPayload.self, from: data),
              payload.device != device else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var settings = model.settings
        settings.effects = payload.effects
        settings.effectPresets = payload.effectPresets
        settings.maxFrameRate = payload.maxFrameRate
        model.settings = settings
        model.applySyncedState(favorites: Set(payload.favorites), tags: payload.tags, playlists: payload.playlists)
        status = .synced(payload.modified)
        Log.info("Synced from \(payload.device)", category: "sync")
    }
}
