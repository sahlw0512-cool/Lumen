import Foundation

/// Locations inside the app's (possibly sandboxed) Application Support folder.
enum AppPaths {
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static let thumbnails: URL = makeDirectory("Thumbnails")
    static let posters: URL = makeDirectory("Posters")
    /// Videos Lumen made itself (slideshows, converted GIFs, Live Photos).
    static let generated: URL = makeDirectory("Generated")
    static let libraryFile: URL = applicationSupport.appendingPathComponent("Library.json")

    private static func makeDirectory(_ name: String) -> URL {
        let url = applicationSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Security-scoped bookmarks: the only way a sandboxed app can reopen a
/// user-selected file after relaunch. They also work (and track moves/renames
/// within a volume) in a non-sandboxed build.
enum BookmarkService {
    struct Resolution {
        let url: URL
        let isStale: Bool
    }

    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Non-sandboxed builds on some configurations refuse security-scoped
            // bookmarks; a regular bookmark still tracks moves and renames.
            do {
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw AppError.bookmarkFailed
            }
        }
    }

    static func resolve(_ data: Data) throws -> Resolution {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return Resolution(url: url, isStale: stale)
        } catch {
            stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return Resolution(url: url, isStale: stale)
        }
    }
}

/// RAII wrapper around `startAccessingSecurityScopedResource()`.
/// Access is released exactly once, when the object is deallocated, so it can
/// never leak or be unbalanced. Calls nest safely (the system reference-counts them).
final class ScopedFileAccess: @unchecked Sendable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}
