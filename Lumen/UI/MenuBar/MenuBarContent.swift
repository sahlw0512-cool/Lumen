import SwiftUI

/// Rendered as a panel (`.menuBarExtraStyle(.window)`) so it can host the
/// volume slider, which a native NSMenu can't show.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nowPlaying
            Divider()
            VolumeControl()
            Divider()
            toggles
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 280)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.displayManager.displays) { display in
                let state = model.engine.displayStates[display.id]
                let title = model.assignedWallpaper(for: display)?.title ?? "System Wallpaper"
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayManager.displays.count > 1 ? "\(display.name): \(title)" : title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let state, state.status != .empty {
                        HStack(spacing: 5) {
                            StatusDot(status: state.status, pauseReason: state.pauseReason)
                            Text(StatusDot.label(status: state.status, pauseReason: state.pauseReason))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.engine.isUserPaused ? "Resume" : "Pause",
                          systemImage: model.engine.isUserPaused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut("p")

                Button {
                    model.nextWallpaper()
                } label: {
                    Label("Next", systemImage: "forward.fill")
                }
                .disabled(model.availableWallpapers.count < 2)

                Menu("Change") {
                    if model.availableWallpapers.isEmpty {
                        Text("Library is empty")
                    }
                    ForEach(model.availableWallpapers.prefix(40)) { wallpaper in
                        Button {
                            model.apply(wallpaper.id)
                        } label: {
                            if model.displays(showing: wallpaper.id).isEmpty {
                                Text(wallpaper.title)
                            } else {
                                Label(wallpaper.title, systemImage: "checkmark")
                            }
                        }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)

            if !model.playlists.isEmpty {
                Menu {
                    ForEach(model.playlists) { playlist in
                        Button {
                            model.startPlaylist(playlist.id)
                        } label: {
                            if model.activePlaylistID == playlist.id {
                                Label(playlist.name, systemImage: "checkmark")
                            } else {
                                Text(playlist.name)
                            }
                        }
                    }
                    if model.activePlaylist != nil {
                        Divider()
                        Button("Stop Playlist") { model.stopPlaylist() }
                    }
                } label: {
                    Label(model.activePlaylist.map { "Playlist: \($0.name)" } ?? "Play a Playlist", systemImage: "rectangle.stack.badge.play")
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Pause on Battery", isOn: Binding(
                get: { model.settings.pauseOnBattery },
                set: { model.settings.pauseOnBattery = $0 }
            ))
            Toggle("Hide Desktop Icons", isOn: Binding(
                get: { model.settings.hideDesktopIcons },
                set: { model.settings.hideDesktopIcons = $0 }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuPanelButton("Open Lumen…") {
                dismiss()
                model.showMainWindow()
            }
            .keyboardShortcut("o")

            SettingsLink {
                Text("Settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MenuPanelButtonStyle())
            .keyboardShortcut(",")

            MenuPanelButton("Quit Lumen") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

/// Wallpaper audio volume, with a mute button that toggles wallpaper audio.
private struct VolumeControl: View {
    @Environment(AppModel.self) private var model

    private var isAudible: Bool {
        model.settings.audioEnabled || model.wallpapers.contains { !$0.soundtracks.isEmpty }
    }

    private var symbol: String {
        let volume = model.settings.audioVolume
        if !model.settings.audioEnabled || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Volume")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    model.settings.audioEnabled.toggle()
                } label: {
                    Image(systemName: symbol)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(model.settings.audioEnabled ? "Mute wallpaper audio" : "Play wallpaper audio")

                Slider(value: Binding(
                    get: { model.settings.audioVolume },
                    set: { model.settings.audioVolume = $0 }
                ), in: 0...1)
                .controlSize(.small)
                .disabled(!isAudible)

                Text("\(Int((model.settings.audioVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/// A full-width, menu-item-looking button for the panel's action list.
private struct MenuPanelButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPanelButtonStyle())
    }
}

private struct MenuPanelButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .background {
                if isHovered || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor)
                }
            }
            .onHover { isHovered = $0 }
    }
}
