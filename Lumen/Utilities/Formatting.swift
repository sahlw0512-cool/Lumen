import Foundation

enum Format {
    /// "0:24", "3:07", "1:02:03". Unknown durations render as an em dash.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func duration(_ seconds: Double) -> String {
        seconds > 0 ? time(seconds) : "—"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func frameRate(_ fps: Double?) -> String {
        guard let fps, fps > 0 else { return "— fps" }
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) fps" : String(format: "%.2f fps", rounded)
    }

    static func bitrate(_ bitsPerSecond: Double?) -> String? {
        guard let bps = bitsPerSecond, bps > 0 else { return nil }
        return bps >= 1_000_000 ? String(format: "%.1f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }

    static func refreshRate(_ hz: Double?) -> String? {
        guard let hz, hz > 0 else { return nil }
        return "\(Int(hz.rounded())) Hz"
    }
}
