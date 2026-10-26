import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Lumen", id: WindowID.main) {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 580)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { LumenCommands(model: model) }

        Settings {
            SettingsView(isEmbedded: false)
                .environment(model)
                .frame(width: 600, height: 680)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showMenuBarItem },
            set: { newValue in
                // SwiftUI re-writes this binding whenever it re-syncs the status
                // item; writing an unchanged value would invalidate the scene and
                // trigger another re-sync, spinning the main thread.
                guard model.settings.showMenuBarItem != newValue else { return }
                model.settings.showMenuBarItem = newValue
            }
        )) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(engine: model.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Kept in its own view so playback-state changes only update the icon,
/// rather than re-evaluating the whole App scene graph.
private struct MenuBarLabel: View {
    let engine: WallpaperEngine

    var body: some View {
        Image(systemName: engine.isAnyPlaying ? "sparkles.tv.fill" : "sparkles.tv")
            .accessibilityLabel("Lumen")
    }
}

struct LumenCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updates.checkNow() }
                .disabled(!model.updates.isConfigured)
        }
        CommandGroup(replacing: .newItem) {
            Button("Import Videos…") {
                model.sidebarSelection = .library
                model.previewWallpaperID = nil
                model.isImporterPresented = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Wallpaper") {
            Button("Pause or Resume Wallpaper") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Reload Wallpapers") { model.reloadAllWallpapers() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Library") { model.sidebarSelection = .library }
                .keyboardShortcut("1", modifiers: .command)
            Button("Displays") { model.sidebarSelection = .displays }
                .keyboardShortcut("2", modifiers: .command)
            Button("Diagnostics") { model.sidebarSelection = .diagnostics }
                .keyboardShortcut("3", modifiers: .command)
            Button("Effects") { model.sidebarSelection = .effects }
                .keyboardShortcut("4", modifiers: .command)
            Button("Performance") { model.sidebarSelection = .performance }
                .keyboardShortcut("5", modifiers: .command)
        }
    }
}
