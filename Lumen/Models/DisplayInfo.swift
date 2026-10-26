import CoreGraphics
import Foundation

/// A snapshot of one connected display. `id` is the display's stable UUID
/// (survives reboots and reconnection), unlike `displayID`, which macOS may
/// reassign whenever the display configuration changes.
struct DisplayInfo: Identifiable, Equatable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    var name: String
    /// Frame in AppKit global coordinates (origin at bottom-left of the primary display).
    var frame: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
    var backingScale: Double
    var refreshRate: Double?
    var rotation: Double
    var isMain: Bool
    var isBuiltIn: Bool
    var supportsEDR: Bool

    var aspectRatio: Double {
        frame.height > 0 ? frame.width / frame.height : 16.0 / 9.0
    }

    var pixelsLabel: String { "\(pixelWidth) × \(pixelHeight)" }

    var pointsLabel: String {
        let scale = backingScale.rounded() == backingScale ? "\(Int(backingScale))" : String(format: "%.1f", backingScale)
        return "\(Int(frame.width)) × \(Int(frame.height)) pt @\(scale)x"
    }
}
