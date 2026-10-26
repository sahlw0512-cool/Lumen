import AppKit

/// Determines which displays are covered by a fullscreen (or borderless
/// display-sized) window of another app.
///
/// macOS has no public "fullscreen app is active on display X" API. This uses
/// `CGWindowListCopyWindowInfo` restricted to on-screen windows, reading only
/// bounds, layer, alpha, and owner PID — fields available without Screen
/// Recording permission. It is invoked only in response to Space changes, app
/// activation, and occlusion changes; never on a timer.
struct FullscreenDetector {
    func coveredDisplays(among displays: [DisplayInfo]) -> Set<CGDirectDisplayID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayBounds = displays.map { ($0.displayID, CGDisplayBounds($0.displayID)) }
        var covered = Set<CGDirectDisplayID>()

        for window in windows {
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }

            for (id, screenBounds) in displayBounds where !covered.contains(id) {
                // Ordinary windows can't overlap the menu bar, so a layer-0 window
                // covering the whole display is a fullscreen or kiosk-style window.
                let overlap = bounds.intersection(screenBounds)
                if overlap.width >= screenBounds.width - 1 && overlap.height >= screenBounds.height - 1 {
                    covered.insert(id)
                }
            }
        }
        return covered
    }
}
