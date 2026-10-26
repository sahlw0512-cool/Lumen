import Foundation

/// The library is a small JSON document written atomically to Application
/// Support. Videos are never stored; only metadata and bookmarks.
struct LibraryStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.libraryFile) {
        self.fileURL = fileURL
    }

    func load() -> LibraryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LibraryDocument() }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LibraryDocument.self, from: data)
        } catch {
            // Keep the unreadable file for inspection rather than silently overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.error("Library file was unreadable and has been backed up: \(error.localizedDescription)", category: "persistence")
            return LibraryDocument()
        }
    }

    func save(_ document: LibraryDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic])
    }
}

struct SettingsStore {
    private let key = "settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
