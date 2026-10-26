import Foundation
import Observation
import OSLog

/// In-app ring buffer of recent events, mirrored to the unified log
/// (`log stream --predicate 'subsystem == "<bundle id>"'`).
/// Messages never include file contents; file names are only logged as
/// wallpaper titles, which stay on this Mac.
@MainActor
@Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    enum Level: String, Sendable {
        case debug, info, warning, error

        var symbol: String {
            switch self {
            case .debug: "ant"
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let level: Level
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let capacity = 500

    func record(_ level: Level, category: String, message: String) {
        entries.append(Entry(date: Date(), level: level, category: category, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() { entries.removeAll() }

    var exportText: String {
        let formatter = ISO8601DateFormatter()
        return entries.map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.category): \($0.message)" }
            .joined(separator: "\n")
    }
}

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.Lumen"

    static func debug(_ message: String, category: String = "app") { write(.debug, category, message) }
    static func info(_ message: String, category: String = "app") { write(.info, category, message) }
    static func warning(_ message: String, category: String = "app") { write(.warning, category, message) }
    static func error(_ message: String, category: String = "app") { write(.error, category, message) }

    private static func write(_ level: DiagnosticsLog.Level, _ category: String, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info: logger.info("\(message, privacy: .private)")
        case .warning: logger.warning("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
        #if !DEBUG
        if level == .debug { return }
        #endif
        Task { @MainActor in
            DiagnosticsLog.shared.record(level, category: category, message: message)
        }
    }
}
