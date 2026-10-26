import SwiftUI

struct WallpaperCard: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let onRename: () -> Void
    let onRemove: () -> Void
    var onEditTags: () -> Void = {}

    @State private var isHovering = false

    private var appliedDisplays: [DisplayInfo] { model.displays(showing: wallpaper.id) }
    private var isApplied: Bool { !appliedDisplays.isEmpty }
    private var meta: VideoMetadata { wallpaper.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(meta.dimensionsLabel) · \(meta.aspectLabel) · \(meta.codecName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.22), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { preview() }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(wallpaper.title), \(meta.resolutionLabel), \(Format.duration(meta.duration))\(isApplied ? ", on desktop" : "")")
        .accessibilityAction(named: "Preview") { preview() }
        .accessibilityAction(named: "Set as Wallpaper") { model.apply(wallpaper.id) }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay { ThumbnailImage(wallpaper: wallpaper) }
            .overlay {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { badges.padding(9) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if isApplied { appliedBadge }
                    favoriteButton
                }
                .padding(9)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(Format.duration(meta.duration))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(9)
            }
            .overlay { hoverActions }
            .overlay { if !wallpaper.isAvailable { missingOverlay } }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(isApplied ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isApplied ? 2 : 1)
            }
            .shadow(color: .black.opacity(isHovering ? 0.32 : 0.16), radius: isHovering ? 16 : 7, y: isHovering ? 9 : 3)
    }

    private var badges: some View {
        HStack(spacing: 5) {
            Chip(text: meta.resolutionLabel)
            if meta.isHDR { Chip(text: "HDR") }
            if meta.aspectClass == .portrait || meta.aspectClass == .ultrawide { Chip(text: meta.aspectClass.title) }
            if !meta.isHardwareDecodable { Chip(text: "Software", symbol: "cpu") }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if wallpaper.isFavorite || isHovering {
            Button {
                model.toggleFavorite(wallpaper.id)
            } label: {
                Image(systemName: wallpaper.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(wallpaper.isFavorite ? Color.yellow : Color.white)
                    .padding(5)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .help(wallpaper.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    private var appliedBadge: some View {
        Chip(text: appliedDisplays.count > 1 ? "On \(appliedDisplays.count) Displays" : "On Desktop",
             symbol: "checkmark", prominent: true)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if wallpaper.isAvailable {
            HStack(spacing: 10) {
                CardActionButton(title: "Preview", symbol: "play.fill") { preview() }
                CardActionButton(title: isApplied ? "Applied" : "Set", symbol: "checkmark.circle.fill") {
                    model.apply(wallpaper.id)
                }
            }
            .environment(\.colorScheme, .dark)
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.94)
            .animation(.snappy(duration: 0.2), value: isHovering)
        }
    }

    private var missingOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.6))
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text("File Missing")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Button("Locate…") { locate() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Preview", systemImage: "play.rectangle") { preview() }
            .disabled(!wallpaper.isAvailable)
        Button("Set on All Displays", systemImage: "display.2") { model.apply(wallpaper.id) }
            .disabled(!wallpaper.isAvailable)
        if model.displayManager.displays.count > 1 {
            Menu("Set on Display") {
                ForEach(model.displayManager.displays) { display in
                    Button(display.name) { model.apply(wallpaper.id, to: display.id) }
                }
            }
            .disabled(!wallpaper.isAvailable)
        }
        Divider()
        Button(wallpaper.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: wallpaper.isFavorite ? "star.slash" : "star") { model.toggleFavorite(wallpaper.id) }
        Button("Tags…", systemImage: "tag") { onEditTags() }
        Menu("Add to Playlist") {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { model.addToPlaylist(wallpaper.id, playlistID: playlist.id) }
                    .disabled(playlist.wallpaperIDs.contains(wallpaper.id))
            }
            if !model.playlists.isEmpty { Divider() }
            Button("New Playlist") { model.createPlaylist(named: wallpaper.title, with: [wallpaper.id]) }
        }
        Button("Span Across Displays", systemImage: "rectangle.split.3x1") { model.startSpan(wallpaper.id) }
            .disabled(!wallpaper.isAvailable || model.displayManager.displays.count < 2)
        Divider()
        Button("Rename…", systemImage: "pencil") { onRename() }
        Button("Show in Finder", systemImage: "folder") { model.revealInFinder(wallpaper.id) }
            .disabled(!wallpaper.isAvailable)
        Button("Regenerate Thumbnail", systemImage: "photo") { model.regenerateThumbnail(wallpaper.id) }
            .disabled(!wallpaper.isAvailable)
        if !wallpaper.isAvailable {
            Button("Locate File…", systemImage: "magnifyingglass") { locate() }
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive) { onRemove() }
    }

    private func preview() {
        guard wallpaper.isAvailable else { return }
        model.previewWallpaperID = wallpaper.id
    }

    private func locate() {
        if let url = FilePanels.chooseVideo(message: "Locate “\(wallpaper.title)”") {
            model.relink(wallpaper.id, to: url)
        }
    }
}

private struct CardActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
