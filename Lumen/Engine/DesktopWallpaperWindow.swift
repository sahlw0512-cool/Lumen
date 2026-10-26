import AppKit

// A borderless window in the desktop layer of the window server.
//
// Level: kCGDesktopWindowLevel, the same level as the system wallpaper.
// It sits below Finder's desktop icons, normal windows, the Dock and the menu bar.
//
// Collection behavior:
//   canJoinAllSpaces - present on every Space of its display
//   stationary       - not moved by Mission Control or Show Desktop
//   ignoresCycle     - never part of Command-backtick window cycling
final class DesktopWallpaperWindow: NSWindow {
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    /// One step above Finder's desktop icons, still far below normal windows.
    static let aboveIconsLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// Covering the icons hides them without touching Finder's preferences
    /// (which the sandbox doesn't allow) or relaunching Finder.
    var coversDesktopIcons = false {
        didSet { level = coversDesktopIcons ? Self.aboveIconsLevel : Self.desktopLevel }
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        level = DesktopWallpaperWindow.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = NSColor.black
        isReleasedWhenClosed = false
        isRestorable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // Hiding the app (Command-H) must not hide the desktop.
        canHide = false
        displaysWhenScreenProfileChanges = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

    // AppKit normally pushes windows below the menu bar; a wallpaper must span
    // the full display (the menu bar and Dock are drawn above it anyway).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
