# Lumen — native animated wallpapers for macOS

Lumen plays your own videos as a real desktop background on macOS. The video sits behind Finder's desktop icons and every app window, and each display can have its own wallpaper. It uses only Swift, SwiftUI, AppKit, and AVFoundation. It has no Electron, no web view, no helper process, and no private frameworks.

## Download

Get the latest `Lumen-x.y.z.dmg` from the [Releases](../../releases/latest) page. Open it and drag Lumen into Applications. Lumen needs macOS 14 or later and runs on Apple silicon and Intel Macs.

**First launch:** Lumen isn't notarized by Apple, so macOS blocks it the first time. Open Lumen once, then go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Lumen. You only need to do this once per version.

Lumen checks this page for new versions and offers to download them. Your library and settings are kept when you update.

## Making a release

1. Run `Scripts/release.sh 1.1.0` (any new version number). It sets the version, builds a universal app, and writes `dist/Lumen-1.1.0.dmg`.
2. On GitHub, go to **Releases › Draft a new release**, create the tag `v1.1.0`, write what changed, attach the DMG, and publish.

---

## 1. How to show a real animated wallpaper on macOS

### What macOS provides publicly

| Need | Public, documented API | Notes |
|---|---|---|
| Draw behind icons and windows | `NSWindow` at `CGWindowLevelForKey(.desktopWindow)` | The same level as the system wallpaper. It is below `kCGDesktopIconWindowLevel` (Finder icons), normal windows, the Dock, and the menu bar. |
| Appear on every Space; ignore Exposé | `NSWindow.CollectionBehavior` `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle` | `.stationary` makes Mission Control and Show Desktop leave the window in place, as they do with the real wallpaper. |
| Let clicks pass through | `ignoresMouseEvents = true` plus `hitTest` returning nil | Clicks reach Finder's desktop window, so icons, marquee selection, and "click wallpaper to reveal desktop" keep working. |
| Hardware video decode and presentation | `AVPlayer` / `AVPlayerLayer`, which use VideoToolbox | Frames go to the window server as IOSurfaces. No app code runs per frame. |
| Gapless looping | `AVQueuePlayer` + `AVPlayerLooper` | The next copy of the item is pre-rolled, so there is no seek and no black frame at the loop point. |
| Display changes | `NSApplication.didChangeScreenParametersNotification`, `CGDisplayCreateUUIDFromDisplayID` | The display UUID is stable across reconnects. |
| Is the window visible? | `NSWindow.occlusionState` plus its notification | Event-driven. |
| Sleep, wake, display sleep, user switching | `NSWorkspace` notifications | |
| Battery and Low Power Mode | `IOPSNotificationCreateRunLoopSource`, `NSProcessInfoPowerStateDidChange` | Event-driven. |
| Login item | `SMAppService.mainApp` | macOS 13+. Replaces the deprecated APIs. |
| Static system wallpaper | `NSWorkspace.setDesktopImageURL(_:for:options:)` | Used for the optional "match desktop picture" feature. |

### What macOS does *not* provide publicly, and how Lumen handles it

| Behavior | Reality | What Lumen does |
|---|---|---|
| Replacing the system wallpaper with video | No public API. Apple's own dynamic and Aerial wallpapers use private WallpaperAgent extensions. | Uses a desktop-level window instead. Nothing is injected and SIP is not touched. |
| A different wallpaper per Space | A desktop-level window can't be bound to one Space and still behave like the wallpaper. | One wallpaper per display, shown on every Space of that display. |
| Animated thumbnails in Mission Control's Spaces bar or on the lock screen | These are rendered by the system from the *static* desktop picture. | Optional **Match the macOS desktop picture** setting. It sets a full-resolution poster frame as the static picture and restores your originals when turned off or when Lumen quits. |
| A "fullscreen app on display X" event | None exists. | Reads `CGWindowListCopyWindowInfo` (bounds, layer, and PID only; no Screen Recording permission needed) once, 400 ms after each Space change or app activation. It never polls. |
| Lock-screen and screen-saver events | Only via undocumented distributed notifications (`com.apple.screenIsLocked`, `com.apple.screensaver.didstart`, and their counterparts). | Uses them, cross-checked against `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`. If Apple stops posting them, display sleep and session-resign events still pause playback. Lumen never draws on the lock screen. |
| A "user went idle" event | None exists. | One one-shot timer set for the moment the idle threshold could first be reached. While idle, event monitors detect the user's return. |

**Why not a higher window level?** At `desktopIconWindow` or above, the video would cover the icons. At `normal` or above, it would cover apps. Below `desktopWindow`, the system wallpaper hides it. The window level is a single constant (`DesktopWallpaperWindow.desktopLevel`), and the whole backend sits behind the `WallpaperRenderer` protocol, so it can be replaced later without changing the engine or the UI.

### Known limitations (stated plainly)

* **Space switch animation:** The video stays fixed while windows slide, because the window is `.stationary` on all Spaces. The system wallpaper slides with the Space. This is usually invisible unless Spaces have different system pictures. Turn on *Match the macOS desktop picture* to make them match.
* **Mission Control's Spaces bar, the lock screen, and the login window** show the static system picture, not the video.
* **`setDesktopImageURL` affects only the current Space** of each display. That's a macOS restriction.
* **Occlusion-based pausing** depends on the window server's occlusion reporting for desktop-level windows. If you ever see a frozen wallpaper while it's visible, turn off *Pause when fully covered by windows* and report it. The Diagnostics screen shows the live pause reason for each display.
* **Fullscreen detection** is a heuristic. A borderless app window covering an entire display, such as a kiosk or some games, also counts as fullscreen.
* **Launchpad** (where it still exists) and **Notification Center** draw above everything. Lumen doesn't interact with them.

---

## 2. Architecture

```
LumenApp (SwiftUI scenes: Window, Settings, MenuBarExtra)
 └─ AppDelegate ── start() / shutdown()
     └─ AppModel (@MainActor @Observable) — library, assignments, settings, intents
         ├─ LibraryStore / SettingsStore ── JSON in Application Support / UserDefaults
         ├─ ImportService ── MediaProbe (protocol) ← AVFoundationMediaProbe
         │                └─ ThumbnailService (disk + bounded NSCache)
         ├─ StaticWallpaperSync (optional system-picture matching)
         ├─ DisplayManager ── screen-parameter notifications
         └─ WallpaperEngine (@MainActor) ── PlaybackPolicy (pure function)
              ├─ PowerMonitor · SystemStateMonitor · IdleMonitor · FullscreenDetector
              └─ WallpaperRenderer (protocol) ← DesktopWindowRenderer
                    └─ DisplayWallpaperController (one per display)
                         ├─ DesktopWallpaperWindow (desktop level, all Spaces, click-through)
                         ├─ VideoSurfaceView (AVPlayerLayer, GPU crossfade, reveal-when-ready)
                         └─ LoopingVideoPlayer (AVQueuePlayer + AVPlayerLooper)
```

Every playback decision goes through `WallpaperEngine.refreshPlayback()`, which calls `PlaybackPolicy.pauseReason(for:settings:)`. Nothing runs on a timer. A paused `AVPlayer` decodes nothing, and the window server re-composites the last frame for free.

**Quality.** The video is decoded at its native resolution and presented once by `AVPlayerLayer`, with `contentsScale` matching the display's backing scale. There is no transcoding, no CPU pixel copies, and no SwiftUI redraws. AVFoundation handles HDR (PQ/HLG/Dolby Vision) and wide color on EDR displays, and Lumen never converts color. Variable frame rate is honored because AVPlayer presents frames by their timestamps. A new wallpaper is revealed only after `isReadyForDisplay` reports a decoded frame, then crossfaded on the GPU, so changing wallpapers never flashes black.

**Formats.** Anything the installed AVFoundation can decode works: MP4, MOV, and M4V containers holding H.264, HEVC (including alpha and Dolby Vision), ProRes, Motion JPEG, and AV1 where the Mac supports it. **WebM and MKV containers are not supported by AVFoundation**, and Lumen says so honestly. The error message explains how to remux losslessly (`ffmpeg -i in.mkv -c copy out.mp4`) when the video inside is H.264 or HEVC. Each import also detects whether the codec has *hardware* decode on this Mac (`VTIsHardwareDecodeSupported`) and flags software-decoded files.

**Third-party decoders (FFmpeg/libav), evaluated and not included.** Adding them through `MediaProbe` plus a new renderer would mean:
* **Licensing:** LGPL at best, and only with dynamic linking, relinkability, and source offers. Many common builds are GPL (x264/x265), which would force GPL on the whole app.
* **Size:** 20–60 MB.
* **Security:** a large C attack surface parsing untrusted files, with CVEs that need tracking.
* **Maintenance:** rebuilding for each architecture and notarizing it.

Since remuxing solves most MKV cases for free, the decision for v1 is not to ship it.

---

## 3. Xcode setup

**Requirements:** Xcode 16 or later, and macOS 14 Sonoma or later as the deployment target.

**Why macOS 14:** it provides the Observation framework (`@Observable`), `SettingsLink`, `ContentUnavailableView`, `NSApp.activate()`, the async AVFoundation loading APIs, `SMAppService`, and `AVPlayer.defaultRate`. Supporting macOS 13 would mean going back to `ObservableObject` and losing `SettingsLink`. macOS 14 covers every Apple Silicon Mac and the Intel Macs from 2018 onward.

### Option A — XcodeGen (recommended)
```bash
brew install xcodegen
cd Lumen
xcodegen generate
open Lumen.xcodeproj
```
`project.yml` sets up the app target, unit tests, entitlements, hardened runtime, and the build settings listed below.

### Option B — by hand
1. **File ▸ New ▸ Project ▸ macOS ▸ App.** Product Name `Lumen`, Interface **SwiftUI**, Language **Swift**, Testing **XCTest** (Storage: None).
2. Delete the generated `ContentView.swift` and `LumenApp.swift`.
3. Drag the `Lumen/` folder's subfolders (`App`, `Models`, `Services`, `Monitors`, `Engine`, `UI`, `Utilities`), `Assets.xcassets`, and `Lumen.entitlements` into the app target. Replace the template's asset catalog. Drag `LumenTests/LumenTests.swift` into the test target.
4. **Target ▸ General:** set Minimum Deployment to **macOS 14.0**.
5. **Target ▸ Build Settings:**
   * Swift Language Version → **Swift 5**
   * Strict Concurrency Checking → **Minimal**
   * *(Xcode 26 only)* Default Actor Isolation → **nonisolated**, Approachable Concurrency → **No**
   * Code Signing Entitlements → `Lumen/Lumen.entitlements`
   * Enable Hardened Runtime → **Yes**
6. **Signing & Capabilities:** choose your Team. App Sandbox should show **User Selected File: Read Only**. (These come from `Lumen.entitlements`.)
7. Build and run (⌘R).

### Entitlements (`Lumen/Lumen.entitlements`)
| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | Sandboxed by default. Desktop-level windows, AVFoundation, IOKit power notifications, and `CGWindowListCopyWindowInfo` bounds all work inside the sandbox. |
| `com.apple.security.files.user-selected.read-only` | Read videos the user picks or drops. Lumen never writes to them. |
| `com.apple.security.files.bookmarks.app-scope` | Security-scoped bookmarks, so files can be reopened after relaunch. |

There are no extra Info.plist keys and no usage-description strings, because Lumen doesn't use the camera, microphone, Accessibility, or Screen Recording. Its Info.plist is generated from `INFOPLIST_KEY_*` build settings.

**Sandbox trade-off:** with the sandbox on, *Match the macOS desktop picture* writes posters into the app container, and the system may not be able to read them on some macOS versions. If that happens, the failure is logged in Diagnostics and nothing else breaks. If you distribute outside the Mac App Store and need that feature to be bulletproof, you can remove `app-sandbox`. Everything else works unchanged, and bookmarks fall back to regular ones.

### Assets
`Assets.xcassets` contains an `AccentColor` and an empty `AppIcon` set. Drop 16–1024 px PNGs into AppIcon before shipping.

### Dependencies
None. The project uses only Apple frameworks: SwiftUI, AppKit, AVFoundation (AVPlayerLayer), CoreMedia, VideoToolbox, ImageIO, UniformTypeIdentifiers, IOKit, ServiceManagement, Observation, and OSLog.

---

## 4. Running and testing

* **Unit tests (⌘U):** cover the playback policy, metadata labels, and settings decoding and migration.
* **Logs:** Console.app with the filter `subsystem:com.example.Lumen`, or the in-app **Diagnostics** screen, which shows live per-display state, pause reasons, and the system state.
* **Performance:** use Instruments ▸ *Activity Monitor* and *Animation Hitches*. You should see near-zero CPU while paused, and video decoding attributed to `VTDecoderXPCService`, not Lumen, when hardware decode is in use. **I haven't measured this; please profile on your hardware before relying on any numbers.**

### Manual test matrix (run each with the wallpaper playing, then record the result)
| # | Scenario | Expected |
|---|---|---|
| 1 | Import a 4K HEVC .mov and an H.264 .mp4 via the button and via drag-and-drop | Cards appear with thumbnail, resolution, duration, and aspect ratio |
| 2 | Import .mkv / .webm / .txt / a corrupted file | A clear error banner with a suggestion, no crash |
| 3 | Apply; click, drag, and rename desktop icons; right-click the desktop | Icons stay above the video and fully usable |
| 4 | Open apps; ⌘-Tab; ⌘` | Windows stay above the wallpaper; the wallpaper never takes focus |
| 5 | Mission Control (F3 / swipe up) | The video stays in the background; windows tile above it |
| 6 | Switch Spaces (⌃→) | The video stays on every Space (see known limitations) |
| 7 | Show Desktop (F11 / spread gesture) | Windows move aside and the video stays |
| 8 | A fullscreen app on one display | That display pauses (Diagnostics: "Fullscreen app"); others keep playing |
| 9 | Connect / disconnect an external display | A surface is created or released; assignments are remembered |
| 10 | Change resolution, scaling, rotation, primary display, and arrangement | The wallpaper refits with no gaps |
| 11 | Sleep and wake; display sleep | Pauses, then resumes; failed players are rebuilt |
| 12 | Lock (⌃⌘Q) and unlock; start the screen saver | Pauses, then resumes; nothing appears over the lock screen |
| 13 | Unplug power with *Pause on battery* on; toggle Low Power Mode | Pauses and resumes |
| 14 | Quit from the menu bar; relaunch | The desktop returns to the system picture; the wallpaper is restored on relaunch |
| 15 | Rename or move the video in Finder, then relaunch | The bookmark follows the file |
| 16 | Delete the video (or unmount its drive), then relaunch | The card shows "File Missing" with **Locate…**; the display falls back to the system picture |

---

## 5. Building a distributable app (Developer ID)

1. Set your Team and a real bundle ID (`PRODUCT_BUNDLE_IDENTIFIER`). Hardened Runtime is already on.
2. **Product ▸ Archive ▸ Distribute App ▸ Direct Distribution.** Xcode signs with Developer ID and submits for notarization.
   Or from the command line:
   ```bash
   xcodebuild -scheme Lumen -configuration Release -archivePath build/Lumen.xcarchive archive
   xcodebuild -exportArchive -archivePath build/Lumen.xcarchive -exportPath build -exportOptionsPlist ExportOptions.plist
   xcrun notarytool submit build/Lumen.zip --keychain-profile AC_NOTARY --wait
   xcrun stapler staple build/Lumen.app
   ```
3. Ship it as a DMG or ZIP. `SMAppService` launch-at-login works without changes for apps in /Applications.

The code uses no private APIs and needs no exception entitlements. The two undocumented notification names (lock and screen saver) are just string observers, and they're compatible with notarization and Mac App Store review.

---

## 6. Project structure

```
Lumen/
├─ project.yml                      XcodeGen spec
├─ README.md
├─ Lumen/
│  ├─ Lumen.entitlements
│  ├─ Assets.xcassets/              AccentColor, AppIcon
│  ├─ App/        LumenApp.swift · AppDelegate.swift · AppModel.swift
│  ├─ Models/     Wallpaper.swift · VideoMetadata.swift · AppSettings.swift · DisplayInfo.swift
│  ├─ Services/   FileAccess.swift · MediaProbe.swift · ImportService.swift · ThumbnailService.swift
│  │              PersistenceService.swift · LaunchAtLoginService.swift · StaticWallpaperSync.swift
│  ├─ Monitors/   DisplayManager.swift · PowerMonitor.swift · SystemStateMonitor.swift
│  │              IdleMonitor.swift · FullscreenDetector.swift
│  ├─ Engine/     WallpaperRenderer.swift · DesktopWallpaperWindow.swift · VideoSurfaceView.swift
│  │              LoopingVideoPlayer.swift · PlaybackPolicy.swift · WallpaperEngine.swift
│  ├─ UI/         RootView.swift · Components/Components.swift
│  │              Library/LibraryView.swift · Library/WallpaperCard.swift
│  │              Preview/PreviewView.swift · Preview/PreviewPlayerModel.swift
│  │              Displays/DisplaysView.swift · Settings/SettingsView.swift
│  │              Diagnostics/DiagnosticsView.swift · MenuBar/MenuBarContent.swift
│  └─ Utilities/  AppError.swift · Formatting.swift · Diagnostics.swift
└─ LumenTests/    LumenTests.swift
```
