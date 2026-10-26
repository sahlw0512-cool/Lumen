import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.applyActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lumen's only always-on windows are desktop-level wallpaper windows,
        // which macOS doesn't count as "visible". Without this, the system
        // treats the app as idle and silently quits it (automatic termination).
        ProcessInfo.processInfo.disableAutomaticTermination("Lumen is rendering the desktop wallpaper")
        ProcessInfo.processInfo.disableSuddenTermination()
        AppModel.shared.start()
    }

    /// The desktop wallpaper windows count as "visible", so AppKit's default
    /// Dock-click handling thinks a window is already showing and does nothing.
    /// Always bring the library window back instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showMainWindow()
        return false
    }

    /// The wallpaper keeps running after the library window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
