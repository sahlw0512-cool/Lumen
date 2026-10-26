import AppKit
import Observation

/// Checks GitHub Releases for a newer version of Lumen.
///
/// Publishing an update = making a GitHub release whose tag is the new
/// version (for example `v1.1.0`) with the DMG from `Scripts/release.sh`
/// attached. Lumen compares the tag with its own version and offers the DMG.
/// It only reads the public release list; nothing about the user is sent.
@MainActor
@Observable
final class UpdateChecker {
    /// "owner/repository" on GitHub. Empty turns update checks off.
    static let repository = ""

    struct Release: Equatable {
        var version: String
        var notes: String
        /// The attached .dmg (or .zip), else the release page.
        var downloadURL: URL
        var pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    var checksAutomatically: Bool = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    var isConfigured: Bool { !Self.repository.isEmpty }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private enum Keys {
        static let automatic = "updates.automatic"
        static let lastChecked = "updates.lastChecked"
        static let skipped = "updates.skippedVersion"
    }

    /// At launch: checks at most once a day, and only alerts about a version
    /// the user hasn't skipped.
    func checkInBackgroundIfDue() {
        guard isConfigured, checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 60 * 60 { return }
        Task {
            await check()
            if case .available(let release) = state,
               release.version != UserDefaults.standard.string(forKey: Keys.skipped) {
                presentAlert(for: release)
            }
        }
    }

    /// "Check for Updates…": always checks and always reports the result.
    func checkNow() {
        Task {
            await check()
            switch state {
            case .available(let release): presentAlert(for: release)
            case .upToDate: presentMessage("You're up to date", "Lumen \(Self.currentVersion) is the latest version.")
            case .failed(let message): presentMessage("Couldn't check for updates", message)
            case .idle, .checking: break
            }
        }
    }

    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL)
    }

    private func check() async {
        guard isConfigured else {
            state = .failed("Updates aren't set up for this copy of Lumen.")
            return
        }
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lumen/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                state = .failed(status == 404 ? "No releases have been published yet." : "GitHub returned error \(status).")
                return
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            let version = latest.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard Self.isVersion(version, newerThan: Self.currentVersion) else {
                state = .upToDate
                return
            }
            let asset = latest.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                ?? latest.assets.first { $0.name.lowercased().hasSuffix(".zip") }
            state = .available(Release(version: version, notes: latest.body ?? "",
                                       downloadURL: asset?.browserDownloadURL ?? latest.htmlURL,
                                       pageURL: latest.htmlURL))
            Log.info("Lumen \(version) is available", category: "app")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Compares dotted versions numerically: 1.10 is newer than 1.9.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private func presentAlert(for release: Release) {
        let alert = NSAlert()
        alert.messageText = "Lumen \(release.version) is available"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have \(Self.currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
            + "\n\nDownload the new version, quit Lumen, and drag it into Applications to replace this one. Your library and settings are kept."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: download(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        default: break
        }
    }

    private func presentMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var body: String?
    var htmlURL: URL
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case assets
    }
}
