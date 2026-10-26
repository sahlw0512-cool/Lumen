import AppKit
import AVFoundation
import Photos
import PhotosUI
import Observation
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case library, playlists, displays, effects, performance, settings, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .displays: "Displays"
        case .effects: "Effects"
        case .performance: "Performance"
        case .settings: "Settings"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .playlists: "rectangle.stack.badge.play"
        case .displays: "display.2"
        case .effects: "camera.filters"
        case .performance: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }
}

/// Quick filters above the library grid.
enum LibraryFilter: Hashable {
    case all, favorites, uhd, hdr, portrait, withAudio
    case tag(String)

    static let standard: [LibraryFilter] = [.all, .favorites, .uhd, .hdr, .portrait, .withAudio]

    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .uhd: "4K+"
        case .hdr: "HDR"
        case .portrait: "Portrait"
        case .withAudio: "Has Audio"
        case .tag(let tag): tag
        }
    }

    var symbol: String? {
        switch self {
        case .favorites: "star.fill"
        case .tag: "tag"
        default: nil
        }
    }

    func matches(_ wallpaper: Wallpaper) -> Bool {
        let meta = wallpaper.metadata
        switch self {
        case .all: return true
        case .favorites: return wallpaper.isFavorite
        case .uhd: return max(meta.pixelWidth, meta.pixelHeight) >= 3840
        case .hdr: return meta.isHDR
        case .portrait: return meta.aspectClass == .portrait
        case .withAudio: return meta.hasAudio || !wallpaper.soundtracks.isEmpty
        case .tag(let tag): return wallpaper.tags.contains(tag)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Application state and the single place where library, displays, settings,
/// and the playback engine meet. Views read from it and call its intents.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Persistent state

    private(set) var wallpapers: [Wallpaper] = []
    private(set) var assignments: [String: DisplayAssignment] = [:]
    private(set) var lastAppliedWallpaperID: UUID?
    private(set) var span: SpanConfiguration?
    private(set) var audioDisplayKey: String?
    private(set) var playlists: [Playlist] = []
    private(set) var activePlaylistID: UUID?
    private(set) var schedule = WallpaperSchedule()
    var settings: AppSettings {
        didSet {
            // No-op writes must not re-save, re-sync the engine, or feed update loops.
            guard settings != oldValue else { return }
            settingsDidChange(from: oldValue)
        }
    }

    // MARK: UI state

    var sidebarSelection: SidebarItem? = .library
    var previewWallpaperID: UUID?
    var isImporterPresented = false
    var searchText = ""
    var sortOrder: LibrarySortOrder = .dateAdded
    var libraryFilter: LibraryFilter = .all
    /// The Effects page edits this wallpaper's own effects (nil = all wallpapers).
    var effectsScope: UUID?
    var isOnboardingPresented = false
    var isSlideshowCreatorPresented = false
    private(set) var importProgress: ImportProgress?
    /// A slideshow, GIF, or Photos item being turned into a video.
    private(set) var generation: (title: String, fraction: Double)?
    var importFailures: [ImportFailure] = []
    /// Bumped when a thumbnail file is regenerated so views reload it.
    private(set) var thumbnailRevisions: [UUID: Int] = [:]

    // MARK: Services

    let displayManager: DisplayManager
    let engine: WallpaperEngine
    let launchAtLogin = LaunchAtLoginService()
    let updates = UpdateChecker()
    let thumbnails: ThumbnailService
    private let importer: ImportService
    private let libraryStore: LibraryStore
    private let settingsStore: SettingsStore
    private let staticSync: StaticWallpaperSync
    @ObservationIgnored private var resolvedURLs: [UUID: URL] = [:]
    /// Keyed by `Soundtrack.id`. A nil value records a bookmark that didn't resolve.
    @ObservationIgnored private var resolvedSoundtrackURLs: [UUID: URL?] = [:]
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        libraryStore: LibraryStore = LibraryStore(),
        settingsStore: SettingsStore = SettingsStore(),
        thumbnails: ThumbnailService = ThumbnailService(),
        probe: any MediaProbe = AVFoundationMediaProbe(),
        renderer: (any WallpaperRenderer)? = nil
    ) {
        self.libraryStore = libraryStore
        self.settingsStore = settingsStore
        self.thumbnails = thumbnails
        self.importer = ImportService(probe: probe, thumbnails: thumbnails)
        self.staticSync = StaticWallpaperSync(thumbnails: thumbnails)
        self.displayManager = DisplayManager()
        self.engine = renderer.map { WallpaperEngine(renderer: $0) } ?? WallpaperEngine()
        self.settings = settingsStore.load()

        let document = libraryStore.load()
        wallpapers = document.wallpapers
        assignments = document.assignments
        lastAppliedWallpaperID = document.lastAppliedWallpaperID
        span = document.span
        audioDisplayKey = document.audioDisplayKey
        playlists = document.playlists ?? []
        activePlaylistID = document.activePlaylistID
        schedule = document.schedule ?? WallpaperSchedule()
    }

    @ObservationIgnored private(set) lazy var rotation = RotationController(model: self)
    @ObservationIgnored let hotkeys = GlobalHotkeys()
    @ObservationIgnored private(set) lazy var cloudSync = CloudSync(model: self)

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Log.info("Lumen starting with \(wallpapers.count) wallpaper(s)", category: "app")

        validateLibrary()
        thumbnails.removeOrphans(keeping: Set(wallpapers.compactMap(\.thumbnailFileName)))

        displayManager.onChange = { [weak self] displays in self?.displaysChanged(displays) }
        displayManager.start()

        engine.onPermanentFailure = { [weak self] id, message in self?.recordPlaybackFailure(id, message: message) }
        engine.start(settings: settings, displays: displayManager.displays)
        engine.system.onWillCover = { [weak self] in self?.showCurrentFrameOnLockScreen() }
        rememberDisplayNames()
        syncRenderer(animated: true)

        // A previous session that synced the static picture and then crashed.
        if !settings.syncStaticDesktopPicture && staticSync.hasSavedOriginals {
            staticSync.restoreAll(screens: NSScreen.screens, displays: displayManager.displays)
        }
        launchAtLogin.refresh()
        rotation.start()
        configureHotkeys()
        cloudSync.setEnabled(settings.iCloudSyncEnabled)
        updates.checkInBackgroundIfDue()
        if !settings.hasCompletedOnboarding && wallpapers.isEmpty { isOnboardingPresented = true }
    }

    /// Called from `applicationWillTerminate`. Releases every window, player,
    /// decoder, and security-scoped file handle before the process exits.
    func shutdown() {
        importTask?.cancel()
        rotation.stop()
        hotkeys.unregisterAll()
        // Keeping the frame lets the login window show it after logout or restart.
        if settings.syncStaticDesktopPicture && !settings.keepLockScreenPictureAfterQuit {
            staticSync.restoreAll(screens: NSScreen.screens, displays: displayManager.displays)
        }
        engine.shutdown()
        displayManager.stop()
        persistLibrary()
        settingsStore.save(settings)
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    /// Captured from the scene so AppKit callbacks (Dock clicks) can reopen
    /// the main window after it has been closed.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    /// Brings the library window back whether it is hidden, minimized, behind
    /// other apps, or closed.
    func showMainWindow() {
        NSApp.unhide(nil)
        let mainWindow = NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix(WindowID.main) == true && !($0 is DesktopWallpaperWindow)
        }
        if let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: WindowID.main)
        }
        NSApp.activate()
    }

    // MARK: - Library queries

    func wallpaper(id: UUID?) -> Wallpaper? {
        guard let id else { return nil }
        return wallpapers.first { $0.id == id }
    }

    var visibleWallpapers: [Wallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = wallpapers.filter { wallpaper in
            libraryFilter.matches(wallpaper) && (query.isEmpty
                || wallpaper.title.localizedCaseInsensitiveContains(query)
                || wallpaper.metadata.codecName.localizedCaseInsensitiveContains(query)
                || wallpaper.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
        switch sortOrder {
        case .dateAdded: return filtered.sorted { $0.dateAdded > $1.dateAdded }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration: return filtered.sorted { $0.metadata.duration > $1.metadata.duration }
        case .resolution: return filtered.sorted { $0.metadata.pixelWidth * $0.metadata.pixelHeight > $1.metadata.pixelWidth * $1.metadata.pixelHeight }
        }
    }

    var availableWallpapers: [Wallpaper] {
        wallpapers.filter(\.isAvailable).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func displays(showing id: UUID) -> [DisplayInfo] {
        if let span { return span.wallpaperID == id ? displayManager.displays : [] }
        return displayManager.displays.filter { assignments[$0.id]?.wallpaperID == id }
    }

    /// What `display` shows: the spanned wallpaper while spanning, else its own.
    func assignedWallpaper(for display: DisplayInfo) -> Wallpaper? {
        wallpaper(id: span?.wallpaperID ?? assignments[display.id]?.wallpaperID)
    }

    func scaling(for display: DisplayInfo) -> ScalingMode {
        span?.scaling ?? assignments[display.id]?.scaling ?? settings.defaultScaling
    }

    func position(for displayKey: String) -> ContentPosition {
        assignments[displayKey]?.position ?? .centered
    }

    var isSpanning: Bool { span != nil }

    /// The connected display that plays wallpaper audio and soundtracks.
    var audioDisplay: DisplayInfo? {
        let displays = displayManager.displays
        if let key = audioDisplayKey, let chosen = displays.first(where: { $0.id == key }) { return chosen }
        return displays.first(where: \.isMain) ?? displays.first
    }

    struct RememberedDisplay: Identifiable {
        let id: String
        let assignment: DisplayAssignment
    }

    /// Saved assignments for displays that aren't connected right now.
    var rememberedDisplays: [RememberedDisplay] {
        let connected = Set(displayManager.displays.map(\.id))
        return assignments.filter { !connected.contains($0.key) }
            .map { RememberedDisplay(id: $0.key, assignment: $0.value) }
            .sorted { $0.assignment.displayName < $1.assignment.displayName }
    }

    func thumbnailRevision(for id: UUID) -> Int { thumbnailRevisions[id] ?? 0 }

    /// The playable URL for a wallpaper (resolved from its bookmark), or nil if missing.
    func resolvedURL(for wallpaper: Wallpaper) -> URL? {
        if let cached = resolvedURLs[wallpaper.id] { return cached }
        guard let bookmark = wallpaper.bookmark, let resolution = try? BookmarkService.resolve(bookmark) else { return nil }
        resolvedURLs[wallpaper.id] = resolution.url
        return resolution.url
    }

    /// The playable URL for a soundtrack, or nil if its file can't be found.
    func resolvedURL(for soundtrack: Soundtrack) -> URL? {
        if let cached = resolvedSoundtrackURLs[soundtrack.id] { return cached }
        let url = soundtrack.bookmark.flatMap { try? BookmarkService.resolve($0).url }
        resolvedSoundtrackURLs[soundtrack.id] = url
        return url
    }

    // MARK: - Soundtracks

    func addSoundtracks(_ urls: [URL], to id: UUID) {
        let candidates = urls.filter(\.isFileURL)
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            var added: [Soundtrack] = []
            for url in candidates {
                let access = ScopedFileAccess(url: url)
                guard let bookmark = try? BookmarkService.makeBookmark(for: url) else {
                    Log.warning("Couldn't keep access to soundtrack \(url.lastPathComponent)", category: "audio")
                    continue
                }
                let duration = try? await AVURLAsset(url: url).load(.duration).seconds
                withExtendedLifetime(access) {}
                added.append(Soundtrack(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                                        originalPath: url.path, bookmark: bookmark,
                                        duration: duration.flatMap { $0.isFinite ? $0 : nil }))
            }
            guard let self, !added.isEmpty, let index = self.wallpapers.firstIndex(where: { $0.id == id }) else { return }
            self.wallpapers[index].soundtracks.append(contentsOf: added)
            self.persistLibrary()
            self.syncRenderer(animated: false)
            Log.info("Added \(added.count) soundtrack(s) to “\(self.wallpapers[index].title)”", category: "audio")
        }
    }

    /// Renames a soundtrack. An empty title goes back to the file's name.
    func editSoundtrackInfo(_ trackID: UUID, in wallpaperID: UUID, title: String, artist: String) {
        guard let w = wallpapers.firstIndex(where: { $0.id == wallpaperID }),
              let t = wallpapers[w].soundtracks.firstIndex(where: { $0.id == trackID }) else { return }
        let title = title.trimmingCharacters(in: .whitespaces)
        let artist = artist.trimmingCharacters(in: .whitespaces)
        let fileName = URL(fileURLWithPath: wallpapers[w].soundtracks[t].originalPath).deletingPathExtension().lastPathComponent
        wallpapers[w].soundtracks[t].title = title.isEmpty ? fileName : title
        wallpapers[w].soundtracks[t].artist = artist.isEmpty ? nil : artist
        persistLibrary()
    }

    func removeSoundtrack(_ trackID: UUID, from id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[index].soundtracks.removeAll { $0.id == trackID }
        resolvedSoundtrackURLs[trackID] = nil
        persistLibrary()
        syncRenderer(animated: false)
    }

    func moveSoundtrack(_ trackID: UUID, in id: UUID, by offset: Int) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }),
              let from = wallpapers[index].soundtracks.firstIndex(where: { $0.id == trackID }) else { return }
        let to = from + offset
        guard wallpapers[index].soundtracks.indices.contains(to) else { return }
        wallpapers[index].soundtracks.swapAt(from, to)
        persistLibrary()
        syncRenderer(animated: false)
    }

    // MARK: - Applying wallpapers

    /// Shows `id` on one display, or on every connected display when `displayKey` is nil.
    /// A manual choice stops any rotating playlist.
    func apply(_ id: UUID, to displayKey: String? = nil, scaling: ScalingMode? = nil) {
        stopPlaylist()
        applyWallpaper(id, to: displayKey, scaling: scaling)
    }

    private func applyWallpaper(_ id: UUID, to displayKey: String? = nil, scaling: ScalingMode? = nil) {
        guard let wallpaper = wallpaper(id: id) else { return }
        guard wallpaper.isAvailable else {
            Log.warning("Can't apply “\(wallpaper.title)”: file is missing", category: "library")
            return
        }
        if settings.warnAboutSoftwareDecoding && !wallpaper.metadata.isHardwareDecodable {
            Log.warning("“\(wallpaper.title)” uses \(wallpaper.metadata.codecName), which this Mac decodes in software; expect higher CPU use", category: "library")
        }
        if span != nil {
            span = nil
            Log.info("Stopped spanning to apply a wallpaper", category: "library")
        }
        let targets = displayKey.map { [$0] } ?? displayManager.displays.map(\.id)
        for key in targets {
            let name = displayManager.display(withKey: key)?.name ?? assignments[key]?.displayName ?? "Display"
            var assignment = assignments[key] ?? DisplayAssignment(wallpaperID: nil, scaling: nil, displayName: name)
            assignment.wallpaperID = id
            if let scaling { assignment.scaling = scaling == settings.defaultScaling ? nil : scaling }
            assignment.displayName = name
            assignments[key] = assignment
        }
        lastAppliedWallpaperID = id
        if let index = wallpapers.firstIndex(where: { $0.id == id }) { wallpapers[index].lastError = nil }
        persistLibrary()
        Log.info("Applied “\(wallpaper.title)” to \(displayKey == nil ? "all displays" : "1 display")", category: "library")
        syncRenderer(animated: true)
    }

    func clearWallpaper(on displayKey: String) {
        guard assignments[displayKey]?.wallpaperID != nil else { return }
        assignments[displayKey]?.wallpaperID = nil
        persistLibrary()
        syncRenderer(animated: true)
    }

    // MARK: - Multi-display studio

    /// Stretches one wallpaper across every connected display.
    func startSpan(_ id: UUID, scaling: ScalingMode? = nil) {
        guard let wallpaper = wallpaper(id: id), wallpaper.isAvailable else { return }
        span = SpanConfiguration(wallpaperID: id, scaling: scaling ?? span?.scaling ?? .fill, position: span?.position)
        lastAppliedWallpaperID = id
        persistLibrary()
        Log.info("Spanning “\(wallpaper.title)” across \(displayManager.displays.count) display(s)", category: "library")
        syncRenderer(animated: true)
    }

    /// Returns every display to its own wallpaper.
    func stopSpan() {
        guard span != nil else { return }
        span = nil
        persistLibrary()
        Log.info("Stopped spanning; displays show their own wallpapers", category: "library")
        syncRenderer(animated: true)
    }

    func setSpanScaling(_ scaling: ScalingMode) {
        guard span != nil, span?.scaling != scaling else { return }
        span?.scaling = scaling
        persistLibrary()
        syncRenderer(animated: false)
    }

    /// Pass `persist: false` while a slider is being dragged; save once at the end.
    func setSpanPosition(_ position: ContentPosition, persist: Bool = true) {
        guard span != nil else { return }
        var position = position
        position.sanitize()
        span?.position = position.isCentered ? nil : position
        if persist { persistLibrary() }
        syncRenderer(animated: false)
    }

    /// nil = the main display.
    func setAudioDisplay(_ key: String?) {
        guard key != audioDisplayKey else { return }
        audioDisplayKey = key
        persistLibrary()
        syncRenderer(animated: false)
    }

    /// Pass `persist: false` while a slider is being dragged; save once at the end.
    func setPosition(_ position: ContentPosition, for displayKey: String, persist: Bool = true) {
        var position = position
        position.sanitize()
        let name = displayManager.display(withKey: displayKey)?.name ?? "Display"
        var assignment = assignments[displayKey] ?? DisplayAssignment(wallpaperID: nil, scaling: nil, displayName: name)
        assignment.position = position.isCentered ? nil : position
        if assignments[displayKey] != assignment {
            assignments[displayKey] = assignment
            syncRenderer(animated: false)
        }
        if persist { persistLibrary() }
    }

    func setScaling(_ scaling: ScalingMode?, for displayKey: String) {
        let name = displayManager.display(withKey: displayKey)?.name ?? "Display"
        var assignment = assignments[displayKey] ?? DisplayAssignment(wallpaperID: nil, scaling: nil, displayName: name)
        assignment.scaling = scaling
        assignments[displayKey] = assignment
        persistLibrary()
        syncRenderer(animated: false)
    }

    func forgetDisplay(_ key: String) {
        assignments[key] = nil
        persistLibrary()
    }

    func togglePause() {
        engine.isUserPaused.toggle()
    }

    func reloadAllWallpapers() {
        resolvedURLs.removeAll()
        resolvedSoundtrackURLs.removeAll()
        validateLibrary()
        engine.reloadAll()
        syncRenderer(animated: false)
    }

    // MARK: - Import

    func importFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        // GIFs aren't playable video; convert them first.
        files.filter(MediaGenerator.isGIF).forEach(convertGIF)
        let candidates = files.filter { !MediaGenerator.isGIF($0) }
        guard !candidates.isEmpty else { return }
        sidebarSelection = .library
        let previous = importTask
        importTask = Task { [weak self] in
            await previous?.value
            await self?.runImport(candidates)
        }
    }

    func dismissImportFailures() {
        importFailures.removeAll()
    }

    private func runImport(_ urls: [URL]) async {
        var progress = ImportProgress(total: urls.count, completed: 0, currentName: "")
        for url in urls {
            if Task.isCancelled { break }
            progress.currentName = url.lastPathComponent
            importProgress = progress

            if isAlreadyInLibrary(url) {
                importFailures.append(ImportFailure(fileName: url.lastPathComponent,
                                                    message: AppError.alreadyInLibrary.errorDescription ?? "",
                                                    suggestion: nil))
            } else {
                do {
                    let wallpaper = try await importer.importVideo(at: url)
                    withAnimation(.snappy) { wallpapers.append(wallpaper) }
                    persistLibrary()
                    Log.info("Imported “\(wallpaper.title)” — \(wallpaper.metadata.dimensionsLabel) \(wallpaper.metadata.codecName), hardware decode: \(wallpaper.metadata.isHardwareDecodable)", category: "import")
                } catch {
                    let appError = AppError.classify(error, fileExtension: url.pathExtension)
                    importFailures.append(ImportFailure(fileName: url.lastPathComponent,
                                                        message: appError.errorDescription ?? error.localizedDescription,
                                                        suggestion: appError.recoverySuggestion))
                    Log.warning("Import failed for a file (\(url.pathExtension)): \(appError.errorDescription ?? "")", category: "import")
                }
            }
            progress.completed += 1
            importProgress = progress
        }
        withAnimation(.easeOut) { importProgress = nil }
    }

    private func isAlreadyInLibrary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return wallpapers.contains { wallpaper in
            let known = resolvedURL(for: wallpaper)?.standardizedFileURL.resolvingSymlinksInPath().path ?? wallpaper.originalPath
            return known == path
        }
    }

    // MARK: - Library management

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[index].title = trimmed
        persistLibrary()
    }

    /// Removes the item from the library. The user's original video is never touched.
    func remove(_ id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        let wallpaper = wallpapers[index]
        withAnimation(.snappy) { _ = wallpapers.remove(at: index) }
        for (key, assignment) in assignments where assignment.wallpaperID == id {
            assignments[key]?.wallpaperID = nil
        }
        if lastAppliedWallpaperID == id { lastAppliedWallpaperID = nil }
        if span?.wallpaperID == id { span = nil }
        if previewWallpaperID == id { previewWallpaperID = nil }
        for index in playlists.indices { playlists[index].wallpaperIDs.removeAll { $0 == id } }
        schedule.entries.removeAll { $0.target == .wallpaper(id) }
        if wallpaper.isGenerated, let url = resolvedURL(for: wallpaper),
           url.path.hasPrefix(AppPaths.generated.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if let name = wallpaper.thumbnailFileName { thumbnails.delete(named: name) }
        resolvedURLs[id] = nil
        persistLibrary()
        syncRenderer(animated: true)
        Log.info("Removed “\(wallpaper.title)” from library (original file kept)", category: "library")
    }

    func removeMissingWallpapers() {
        wallpapers.filter { !$0.isAvailable }.forEach { remove($0.id) }
    }

    /// Points a missing item at a file the user located manually.
    func relink(_ id: UUID, to url: URL) {
        guard let existing = wallpaper(id: id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.importer.importVideo(at: url, replacing: existing)
                guard let index = self.wallpapers.firstIndex(where: { $0.id == id }) else { return }
                self.wallpapers[index] = updated
                self.resolvedURLs[id] = nil
                self.bumpThumbnail(id)
                self.persistLibrary()
                self.syncRenderer(animated: true)
                Log.info("Relinked “\(updated.title)”", category: "library")
            } catch {
                let appError = AppError.classify(error, fileExtension: url.pathExtension)
                self.importFailures.append(ImportFailure(fileName: url.lastPathComponent,
                                                         message: appError.errorDescription ?? error.localizedDescription,
                                                         suggestion: appError.recoverySuggestion))
            }
        }
    }

    func regenerateThumbnail(_ id: UUID) {
        guard let wallpaper = wallpaper(id: id), let url = resolvedURL(for: wallpaper) else { return }
        Task { [weak self] in
            guard let self else { return }
            let access = ScopedFileAccess(url: url)
            defer { withExtendedLifetime(access) {} }
            do {
                let name = try await self.thumbnails.generateThumbnail(for: url, id: id, duration: wallpaper.metadata.duration)
                if let index = self.wallpapers.firstIndex(where: { $0.id == id }) {
                    self.wallpapers[index].thumbnailFileName = name
                }
                self.bumpThumbnail(id)
                self.persistLibrary()
            } catch {
                Log.warning("Thumbnail regeneration failed: \(error.localizedDescription)", category: "library")
            }
        }
    }

    func regenerateAllThumbnails() {
        wallpapers.filter(\.isAvailable).forEach { regenerateThumbnail($0.id) }
    }

    func revealInFinder(_ id: UUID) {
        guard let wallpaper = wallpaper(id: id), let url = resolvedURL(for: wallpaper) else { return }
        let access = ScopedFileAccess(url: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        withExtendedLifetime(access) {}
    }

    func revealLibraryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.libraryFile])
    }

    func resetPreferences() {
        settings = AppSettings()
        Log.info("Preferences reset to defaults", category: "settings")
    }

    func restoreOriginalDesktopPictures() {
        staticSync.restoreAll(screens: NSScreen.screens, displays: displayManager.displays)
    }

    var hasSavedDesktopPictures: Bool { staticSync.hasSavedOriginals }

    // MARK: - Private

    private func bumpThumbnail(_ id: UUID) {
        thumbnailRevisions[id, default: 0] += 1
    }

    private func recordPlaybackFailure(_ id: UUID, message: String) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[index].lastError = message
        // A failure is often a vanished file (unplugged drive); re-check it.
        if let url = resolvedURL(for: wallpapers[index]) {
            let access = ScopedFileAccess(url: url)
            let reachable = (try? url.checkResourceIsReachable()) ?? false
            withExtendedLifetime(access) {}
            if !reachable {
                wallpapers[index].availability = .missing
                resolvedURLs[id] = nil
                syncRenderer(animated: true)
            }
        }
        persistLibrary()
    }

    /// Resolves every bookmark: detects missing files, follows moves/renames,
    /// and refreshes stale bookmarks.
    private func validateLibrary() {
        var changed = false
        for index in wallpapers.indices {
            let wallpaper = wallpapers[index]
            var availability = WallpaperAvailability.missing
            if let bookmark = wallpaper.bookmark, let resolution = try? BookmarkService.resolve(bookmark) {
                let access = ScopedFileAccess(url: resolution.url)
                if (try? resolution.url.checkResourceIsReachable()) == true {
                    availability = .available
                    resolvedURLs[wallpaper.id] = resolution.url
                    if resolution.url.path != wallpaper.originalPath {
                        wallpapers[index].originalPath = resolution.url.path
                        changed = true
                    }
                    if resolution.isStale, let fresh = try? BookmarkService.makeBookmark(for: resolution.url) {
                        wallpapers[index].bookmark = fresh
                        changed = true
                    }
                }
                withExtendedLifetime(access) {}
            }
            if availability != wallpaper.availability {
                wallpapers[index].availability = availability
                changed = true
                if availability == .missing {
                    Log.warning("“\(wallpaper.title)” is missing", category: "library")
                }
            }
            let needsThumbnail = wallpaper.thumbnailFileName.map { !thumbnails.fileExists(named: $0) } ?? true
            if availability == .available && needsThumbnail {
                regenerateThumbnail(wallpaper.id)
            }
        }
        if changed { persistLibrary() }
    }

    private func displaysChanged(_ displays: [DisplayInfo]) {
        engine.updateDisplays(displays)
        rememberDisplayNames()
        syncRenderer(animated: false)
    }

    /// New displays inherit the most recently applied wallpaper.
    private func rememberDisplayNames() {
        var changed = false
        for display in displayManager.displays {
            if var assignment = assignments[display.id] {
                if assignment.displayName != display.name {
                    assignment.displayName = display.name
                    assignments[display.id] = assignment
                    changed = true
                }
            } else if let fallback = lastAppliedWallpaperID, wallpaper(id: fallback)?.isAvailable == true {
                assignments[display.id] = DisplayAssignment(wallpaperID: fallback, scaling: nil, displayName: display.name)
                changed = true
            }
        }
        if changed { persistLibrary() }
    }

    /// Stable per span so spanned surfaces share a sync group across re-syncs.
    private static let spanSyncGroup = UUID()

    private func request(for display: DisplayInfo) -> WallpaperRenderRequest? {
        guard let wallpaper = assignedWallpaper(for: display), wallpaper.isAvailable,
              let url = resolvedURL(for: wallpaper) else { return nil }
        // Audio plays once (on the chosen display); soundtracks replace the video's own audio.
        let playsAudio = display.id == audioDisplay?.id
        let soundtracks = playsAudio ? wallpaper.soundtracks.compactMap(resolvedURL(for:)) : []

        var layout = SurfaceLayout(videoSize: CGSize(width: wallpaper.metadata.pixelWidth, height: wallpaper.metadata.pixelHeight),
                                   scaling: scaling(for: display))
        if let span {
            let union = displayManager.displays.reduce(CGRect.null) { $0.union($1.frame) }
            layout.canvas = SurfaceLayout.spanCanvas(union: union, display: display.frame)
            layout.position = span.position ?? .centered
        } else {
            layout.position = position(for: display.id)
        }

        return WallpaperRenderRequest(
            wallpaperID: wallpaper.id,
            url: url,
            layout: layout,
            loopMode: settings.loopMode,
            muted: !(settings.audioEnabled && playsAudio && wallpaper.metadata.hasAudio) || !soundtracks.isEmpty,
            volume: Float(settings.audioVolume),
            soundtracks: soundtracks,
            syncGroup: span != nil && displayManager.displays.count > 1 ? Self.spanSyncGroup : nil,
            showsClock: settings.effects.clock.onAllDisplays || display.isMain,
            loop: LoopSettings(range: wallpaper.loopRange, crossfade: wallpaper.loopCrossfade),
            adjustments: wallpaper.effects
        )
    }

    private func syncRenderer(animated: Bool) {
        var requests: [String: WallpaperRenderRequest] = [:]
        for display in displayManager.displays {
            if let request = request(for: display) { requests[display.id] = request }
        }
        engine.setContent(requests, animated: animated)
        if settings.syncStaticDesktopPicture {
            for display in displayManager.displays {
                guard let request = requests[display.id], let screen = displayManager.screen(for: display) else { continue }
                staticSync.sync(display: display, screen: screen, videoURL: request.url,
                                wallpaperID: request.wallpaperID, scaling: request.scaling,
                                frameTime: wallpaper(id: request.wallpaperID)?.posterTime ?? 0)
            }
        }
    }

    /// Puts the frame each display is showing on the lock screen, so it
    /// matches the desktop exactly and playback resumes from it after unlocking.
    private func showCurrentFrameOnLockScreen() {
        guard settings.syncStaticDesktopPicture, settings.lockScreenFrame == .latest else { return }
        for display in displayManager.displays {
            guard let request = engine.currentRequest(forDisplay: display.id),
                  let frame = engine.currentFrame(forDisplay: display.id),
                  let screen = displayManager.screen(for: display) else { continue }
            staticSync.syncFrame(frame, display: display, screen: screen,
                                 wallpaperID: request.wallpaperID, scaling: request.scaling)
        }
    }

    private func settingsDidChange(from old: AppSettings) {
        var sanitized = settings
        sanitized.sanitize()
        if sanitized != settings {
            settings = sanitized   // may re-enter; the work below is idempotent
        }
        settingsStore.save(settings)
        engine.updateSettings(settings)

        if settings.showInDock != old.showInDock { applyActivationPolicy() }
        if settings.globalHotkeysEnabled != old.globalHotkeysEnabled { configureHotkeys() }
        if settings.iCloudSyncEnabled != old.iCloudSyncEnabled { cloudSync.setEnabled(settings.iCloudSyncEnabled) }
        if settings.location != old.location { rotation.reschedule() }
        cloudSync.localChange()
        if settings.loopMode != old.loopMode || settings.audioEnabled != old.audioEnabled
            || settings.audioVolume != old.audioVolume || settings.defaultScaling != old.defaultScaling
            || settings.effects.clock.onAllDisplays != old.effects.clock.onAllDisplays {
            syncRenderer(animated: false)
        }
        if settings.syncStaticDesktopPicture != old.syncStaticDesktopPicture {
            if settings.syncStaticDesktopPicture {
                syncRenderer(animated: false)
            } else {
                staticSync.restoreAll(screens: NSScreen.screens, displays: displayManager.displays)
            }
        }
    }

    private func persistLibrary() {
        let document = LibraryDocument(wallpapers: wallpapers, assignments: assignments,
                                       lastAppliedWallpaperID: lastAppliedWallpaperID,
                                       span: span, audioDisplayKey: audioDisplayKey,
                                       playlists: playlists, activePlaylistID: activePlaylistID,
                                       schedule: schedule)
        do {
            try libraryStore.save(document)
        } catch {
            Log.error("Couldn't save library: \(error.localizedDescription)", category: "persistence")
        }
    }
}

// MARK: - Playlists, schedules, organization, effects, loops, lock screen

extension AppModel {
    // MARK: Playlists

    var activePlaylist: Playlist? { playlists.first { $0.id == activePlaylistID } }

    func playlist(id: UUID?) -> Playlist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    @discardableResult
    func createPlaylist(named name: String, with ids: [UUID] = []) -> Playlist {
        let playlist = Playlist(name: name.isEmpty ? "New Playlist" : name, wallpaperIDs: ids)
        playlists.append(playlist)
        persistLibrary()
        return playlist
    }

    func updatePlaylist(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        persistLibrary()
        if playlist.id == activePlaylistID { rotation.reschedule() }
        cloudSync.localChange()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        schedule.entries.removeAll { $0.target == .playlist(id) }
        if activePlaylistID == id { activePlaylistID = nil }
        persistLibrary()
        rotation.reschedule()
        cloudSync.localChange()
    }

    func addToPlaylist(_ wallpaperID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].wallpaperIDs.contains(wallpaperID) else { return }
        playlists[index].wallpaperIDs.append(wallpaperID)
        persistLibrary()
        cloudSync.localChange()
    }

    /// Starts rotating `id`, showing its first (or next) wallpaper now.
    func startPlaylist(_ id: UUID) {
        guard let playlist = playlist(id: id) else { return }
        activePlaylistID = id
        persistLibrary()
        Log.info("Playing playlist “\(playlist.name)”", category: "playlist")
        advancePlaylist()
    }

    func stopPlaylist() {
        guard activePlaylistID != nil else { return }
        activePlaylistID = nil
        persistLibrary()
        rotation.reschedule()
    }

    /// Shows the next wallpaper of the active playlist.
    func advancePlaylist() {
        guard let playlist = activePlaylist else { return }
        let available = Set(wallpapers.filter(\.isAvailable).map(\.id))
        guard let next = playlist.next(after: lastAppliedWallpaperID, available: available) else {
            Log.warning("Playlist “\(playlist.name)” has no available wallpapers", category: "playlist")
            return
        }
        showFromRotation(next)
        rotation.playlistAdvanced()
    }

    /// Next wallpaper: in the active playlist, or alphabetically through the library.
    func nextWallpaper() {
        if activePlaylist != nil {
            advancePlaylist()
            return
        }
        let list = availableWallpapers
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == lastAppliedWallpaperID }.map { ($0 + 1) % list.count } ?? 0
        apply(list[index].id)
    }

    /// Applies without stopping the playlist; keeps spanning if it's on.
    func showFromRotation(_ id: UUID) {
        if span != nil {
            startSpan(id)
        } else {
            applyWallpaper(id)
        }
    }

    // MARK: Schedule

    func setSchedule(_ newSchedule: WallpaperSchedule) {
        guard newSchedule != schedule else { return }
        schedule = newSchedule
        persistLibrary()
        rotation.reschedule()
        rotation.applySchedule(force: true)
        cloudSync.localChange()
    }

    /// Applies what a schedule entry points at.
    func activate(_ target: ScheduleTarget) {
        switch target {
        case .wallpaper(let id):
            if wallpaper(id: id)?.isAvailable == true {
                activePlaylistID = nil
                showFromRotation(id)
            }
        case .playlist(let id):
            if activePlaylistID != id { startPlaylist(id) }
        }
    }

    // MARK: Organization

    func toggleFavorite(_ id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[index].isFavorite.toggle()
        persistLibrary()
        cloudSync.localChange()
    }

    func setTags(_ tags: [String], for id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        wallpapers[index].tags = cleaned
        if case .tag(let tag) = libraryFilter, !allTags.contains(tag) { libraryFilter = .all }
        persistLibrary()
        cloudSync.localChange()
    }

    var allTags: [String] {
        Array(Set(wallpapers.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Effects

    /// nil returns the wallpaper to the global effects.
    func setEffects(_ effects: WallpaperEffects?, for id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        var effects = effects
        effects?.sanitize()
        guard wallpapers[index].effects != effects else { return }
        wallpapers[index].effects = effects
        persistLibrary()
        syncRenderer(animated: false)
    }

    var allEffectPresets: [EffectPreset] { EffectPreset.builtIn + settings.effectPresets }

    func saveEffectPreset(named name: String, effects: WallpaperEffects) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.effectPresets.append(EffectPreset(name: trimmed, effects: effects))
    }

    func deleteEffectPreset(_ id: UUID) {
        settings.effectPresets.removeAll { $0.id == id }
    }

    /// Applies a preset's picture adjustments globally, or to one wallpaper.
    func applyEffectPreset(_ preset: EffectPreset, to wallpaperID: UUID? = nil) {
        if let wallpaperID {
            setEffects(preset.effects.adjustments(appliedTo: settings.effects), for: wallpaperID)
        } else {
            settings.effects = preset.effects.adjustments(appliedTo: settings.effects)
        }
    }

    // MARK: Loops

    func setLoop(start: Double?, end: Double?, crossfade: Double, for id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        let duration = wallpapers[index].metadata.duration
        var start = start.map { max($0, 0) }
        var end = end.map { min($0, duration) }
        if let s = start, s < 0.05 { start = nil }
        if let e = end, duration - e < 0.05 { end = nil }
        if let s = start, let e = end, e - s < 0.5 { end = min(s + 0.5, duration) }
        let fade = min(max(crossfade, 0), 3)
        let wallpaper = wallpapers[index]
        guard wallpaper.trimStart != start || wallpaper.trimEnd != end || wallpaper.loopCrossfade != fade else { return }
        wallpapers[index].trimStart = start
        wallpapers[index].trimEnd = end
        wallpapers[index].loopCrossfade = fade
        persistLibrary()
        syncRenderer(animated: false)
    }

    // MARK: Lock screen, login window, screen saver

    func setPosterTime(_ seconds: Double?, for id: UUID) {
        guard let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[index].posterTime = seconds.map { max($0, 0) }
        persistLibrary()
        if settings.syncStaticDesktopPicture { syncRenderer(animated: false) }
        Log.info("Lock screen frame for “\(wallpapers[index].title)” set to \(Format.time(seconds ?? 0))", category: "sync")
    }

    /// Writes a full-resolution frame to a location the user picks (for the
    /// built-in Photos screen saver, or anything else).
    func exportFrame(of id: UUID, at seconds: Double) {
        guard let wallpaper = wallpaper(id: id), let url = resolvedURL(for: wallpaper) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(wallpaper.title) – \(Format.time(seconds)).jpg"
        panel.message = "Save this frame. To use it as your screen saver, choose its folder in System Settings › Screen Saver › Photos."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let thumbnails = self.thumbnails
        Task {
            do {
                let access = ScopedFileAccess(url: url)
                let image = try await thumbnails.frame(from: url, atSeconds: seconds, maximumSize: nil, exact: true)
                withExtendedLifetime(access) {}
                try ThumbnailService.writeJPEG(image, to: destination, quality: 0.95)
                Log.info("Saved frame to \(destination.lastPathComponent)", category: "sync")
            } catch {
                Log.error("Couldn't save frame: \(error.localizedDescription)", category: "sync")
            }
        }
    }

    // MARK: Generated media

    func convertGIF(_ url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        generate(title: title) { progress in try await MediaGenerator.makeVideo(fromGIF: url, progress: progress) }
    }

    func createSlideshow(from images: [URL], options: MediaGenerator.SlideshowOptions, title: String) {
        generate(title: title.isEmpty ? "Slideshow" : title) { progress in
            try await MediaGenerator.makeSlideshow(from: images, options: options, progress: progress)
        }
    }

    /// Imports videos and Live Photos chosen in the Photos picker. Their files
    /// are copied into Lumen's folder, since Photos only lends them briefly.
    func importFromPhotos(_ items: [PhotosPickerItem]) {
        sidebarSelection = .library
        for (offset, item) in items.enumerated() {
            let title = "Photos Item \(offset + 1)"
            generate(title: title) { progress in
                progress(0.1)
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    return movie.url
                }
                if let live = try await item.loadTransferable(type: PHLivePhoto.self) {
                    return try await LivePhotoExtractor.pairedVideo(of: live)
                }
                throw MediaGenerator.GenerationError.noImages
            }
        }
    }

    private func generate(title: String, work: @escaping (@escaping @Sendable (Double) -> Void) async throws -> URL) {
        sidebarSelection = .library
        generation = (title, 0)
        Task { [weak self] in
            do {
                let url = try await work { fraction in
                    Task { @MainActor in self?.generation = (title, fraction) }
                }
                self?.generation = nil
                self?.importGenerated(url, title: title)
            } catch {
                self?.generation = nil
                self?.importFailures.append(ImportFailure(fileName: title, message: error.localizedDescription,
                                                          suggestion: "Try a different file or fewer images."))
            }
        }
    }

    /// Adds a file Lumen created (slideshow, GIF, Live Photo) to the library.
    func importGenerated(_ url: URL, title: String) {
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                var wallpaper = try await self.importer.importVideo(at: url)
                wallpaper.title = title
                wallpaper.isGenerated = true
                self.wallpapers.append(wallpaper)
                self.persistLibrary()
                Log.info("Created “\(title)”", category: "import")
            } catch {
                self.importFailures.append(ImportFailure(fileName: title, message: error.localizedDescription, suggestion: nil))
            }
        }
    }

    // MARK: Hotkeys & onboarding

    func configureHotkeys() {
        guard settings.globalHotkeysEnabled else {
            hotkeys.unregisterAll()
            return
        }
        hotkeys.register { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePause: self.togglePause()
            case .nextWallpaper: self.nextWallpaper()
            case .showLumen: self.showMainWindow()
            }
        }
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        isOnboardingPresented = false
    }

    // MARK: Sync support

    /// Replaces organization data with values from another Mac. Items are
    /// matched by file name, since each Mac has its own copies of the videos.
    func applySyncedState(favorites: Set<String>, tags: [String: [String]], playlists remote: [SyncedPlaylist]) {
        var changed = false
        for index in wallpapers.indices {
            let name = wallpapers[index].fileName
            let favorite = favorites.contains(name)
            let newTags = tags[name] ?? []
            if wallpapers[index].isFavorite != favorite || wallpapers[index].tags != newTags {
                wallpapers[index].isFavorite = favorite
                wallpapers[index].tags = newTags
                changed = true
            }
        }
        let byName = Dictionary(wallpapers.map { ($0.fileName, $0.id) }, uniquingKeysWith: { first, _ in first })
        for synced in remote {
            var playlist = playlists.first { $0.id == synced.id } ?? Playlist(name: synced.name)
            playlist.id = synced.id
            playlist.name = synced.name
            playlist.wallpaperIDs = synced.fileNames.compactMap { byName[$0] }
            playlist.intervalMinutes = synced.intervalMinutes
            playlist.shuffle = synced.shuffle
            if let index = playlists.firstIndex(where: { $0.id == synced.id }) {
                if playlists[index] != playlist { playlists[index] = playlist; changed = true }
            } else {
                playlists.append(playlist)
                changed = true
            }
        }
        if changed { persistLibrary() }
    }
}
