import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .animation(.smooth(duration: 0.3), value: model.previewWallpaperID)
        }
        .onAppear { model.openWindowAction = openWindow }
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
        }
        .sheet(isPresented: $model.isSlideshowCreatorPresented) {
            SlideshowCreatorView()
                .environment(model)
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: ImportService.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importFiles(urls)
            case .failure(let error):
                Log.warning("Open panel failed: \(error.localizedDescription)", category: "import")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection ?? .library {
        case .library:
            if let id = model.previewWallpaperID {
                PreviewView(wallpaperID: id)
                    .id(id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LibraryView()
                    .transition(.opacity)
            }
        case .playlists:
            PlaylistsView()
        case .displays:
            DisplaysView()
        case .effects:
            EffectsView()
        case .performance:
            PerformanceView()
        case .settings:
            SettingsView(isEmbedded: true)
        case .diagnostics:
            DiagnosticsView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Wallpapers") {
                row(.library, badge: model.wallpapers.count)
                row(.playlists, badge: model.playlists.count)
                row(.displays, badge: model.displayManager.displays.count)
            }
            Section("Customize") {
                row(.effects, badge: 0)
                row(.performance, badge: 0)
            }
            Section("Lumen") {
                row(.settings, badge: 0)
                row(.diagnostics, badge: 0)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            NowPlayingFooter()
                .padding(10)
        }
    }

    /// Rows set the selection themselves instead of relying on
    /// `List(selection:)`: the List couldn't match these rows to a
    /// `SidebarItem` and wrote `nil` on every click, so nothing navigated.
    private func row(_ item: SidebarItem, badge: Int) -> some View {
        SidebarRow(item: item, badge: badge, isSelected: (model.sidebarSelection ?? .library) == item) {
            model.sidebarSelection = item
            // Clicking Library while previewing goes back to the grid.
            if item == .library { model.previewWallpaperID = nil }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let badge: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 18)
                Text(item.title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Compact "what's on the desktop" panel at the bottom of the sidebar.
struct NowPlayingFooter: View {
    @Environment(AppModel.self) private var model

    private var current: Wallpaper? {
        guard let main = model.displayManager.displays.first(where: \.isMain) ?? model.displayManager.displays.first else { return nil }
        return model.assignedWallpaper(for: main)
    }

    private var mainState: WallpaperEngine.DisplayState? {
        guard let main = model.displayManager.displays.first(where: \.isMain) ?? model.displayManager.displays.first else { return nil }
        return model.engine.displayStates[main.id]
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let current {
                    ThumbnailImage(wallpaper: current)
                } else {
                    Rectangle().fill(Theme.placeholderGradient)
                }
            }
            .frame(width: 44, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(current?.title ?? "No wallpaper")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let state = mainState {
                    HStack(spacing: 5) {
                        StatusDot(status: state.status, pauseReason: state.pauseReason)
                        Text(StatusDot.label(status: state.status, pauseReason: state.pauseReason))
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.engine.isUserPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(model.engine.isUserPaused ? "Resume wallpaper" : "Pause wallpaper")
            .disabled(current == nil)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
