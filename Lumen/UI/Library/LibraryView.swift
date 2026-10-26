import PhotosUI
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var renameTarget: Wallpaper?
    @State private var renameText = ""
    @State private var removalTarget: Wallpaper?
    @State private var tagTarget: Wallpaper?
    @State private var isPhotosPickerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: Theme.gridSpacing)]

    var body: some View {
        @Bindable var model = model
        content
            .overlay { dropHighlight }
            .overlay(alignment: .bottom) { ImportStatusBanner().padding(18) }
            .dropDestination(for: URL.self) { urls, _ in
                model.importFiles(urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
            }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
            .toolbar { toolbar }
            .alert("Rename Wallpaper", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let target = renameTarget { model.rename(target.id, to: renameText) }
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                "Remove “\(removalTarget?.title ?? "")” from your library?",
                isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove from Library", role: .destructive) {
                    if let target = removalTarget { model.remove(target.id) }
                    removalTarget = nil
                }
            } message: {
                Text("The original video file stays where it is. Displays using this wallpaper will return to the macOS desktop picture.")
            }
            .sheet(item: $tagTarget) { wallpaper in
                TagEditor(wallpaper: wallpaper)
                    .environment(model)
            }
            .photosPicker(isPresented: $isPhotosPickerPresented, selection: $photoSelection,
                          matching: .any(of: [.videos, .livePhotos]), photoLibrary: .shared())
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                model.importFromPhotos(items)
                photoSelection = []
            }
    }

    private var subtitle: String {
        let count = model.wallpapers.count
        return count == 1 ? "1 wallpaper" : "\(count) wallpapers"
    }

    @ViewBuilder
    private var content: some View {
        if model.wallpapers.isEmpty {
            EmptyLibraryView()
        } else {
            VStack(spacing: 0) {
                FilterBar()
                if model.visibleWallpapers.isEmpty {
                    if model.searchText.isEmpty {
                        ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("No wallpapers match “\(model.libraryFilter.title)”."))
                    } else {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                } else {
                    grid
                }
            }
        }
    }

    private var grid: some View {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(model.visibleWallpapers) { wallpaper in
                        WallpaperCard(
                            wallpaper: wallpaper,
                            onRename: {
                                renameText = wallpaper.title
                                renameTarget = wallpaper
                            },
                            onRemove: { removalTarget = wallpaper },
                            onEditTags: { tagTarget = wallpaper }
                        )
                    }
                }
                .padding(Theme.contentPadding)
                .padding(.bottom, 60)
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: Bindable(model).sortOrder) {
                    ForEach(LibrarySortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort library")

            Button {
                model.togglePause()
            } label: {
                Label(model.engine.isUserPaused ? "Resume" : "Pause",
                      systemImage: model.engine.isUserPaused ? "play.fill" : "pause.fill")
            }
            .help(model.engine.isUserPaused ? "Resume desktop wallpaper" : "Pause desktop wallpaper")

            Menu {
                Button("Videos and GIFs…", systemImage: "film") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
                Button("From Photos…", systemImage: "photo.on.rectangle") { isPhotosPickerPresented = true }
                Button("Create Slideshow…", systemImage: "rectangle.stack") { model.isSlideshowCreatorPresented = true }
            } label: {
                Label("Import", systemImage: "plus")
            } primaryAction: {
                model.isImporterPresented = true
            }
            .help("Import videos (⌘O). Hold for Photos and slideshows.")
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                Label("Drop to Import", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 58, weight: .thin))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: 8) {
                Text("Bring your desktop to life")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Import a video to use it as a living wallpaper behind your icons and windows.\nYour originals stay exactly where they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.isImporterPresented = true
            } label: {
                Label("Import Videos…", systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("or drop files anywhere in this window")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                ForEach(["MP4", "MOV", "M4V", "HEVC", "H.264", "ProRes", "HDR"], id: \.self) { Chip(text: $0) }
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ImportStatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if let generation = model.generation {
                HStack(spacing: 12) {
                    ProgressView(value: generation.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Creating “\(generation.title)”")
                            .font(.callout.weight(.semibold))
                        Text("\(Int(generation.fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let progress = model.importProgress {
                HStack(spacing: 12) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importing \(min(progress.completed + 1, progress.total)) of \(progress.total)")
                            .font(.callout.weight(.semibold))
                        Text(progress.currentName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !model.importFailures.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(model.importFailures.count == 1 ? "1 file couldn't be imported" : "\(model.importFailures.count) files couldn't be imported",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss") { withAnimation { model.dismissImportFailures() } }
                            .buttonStyle(.borderless)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.importFailures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.fileName).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                    Text(failure.message).font(.caption)
                                    if let suggestion = failure.suggestion {
                                        Text(suggestion).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                .padding(14)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.importProgress)
        .animation(.snappy, value: model.importFailures)
    }
}

/// Quick filters and tags above the grid.
private struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryFilter.standard + model.allTags.map(LibraryFilter.tag), id: \.self) { filter in
                    let selected = model.libraryFilter == filter
                    Button {
                        model.libraryFilter = selected ? .all : filter
                    } label: {
                        HStack(spacing: 4) {
                            if let symbol = filter.symbol { Image(systemName: symbol).imageScale(.small) }
                            Text(filter.title)
                        }
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 10)
        }
    }
}

/// Add and remove tags on one wallpaper.
private struct TagEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let wallpaper: Wallpaper
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags for “\(wallpaper.title)”").font(.headline)
            HStack {
                TextField("Add a tag", text: $newTag)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !tags.isEmpty {
                FlowTags(tags: tags) { tag in tags.removeAll { $0 == tag } }
            }
            let suggestions = model.allTags.filter { !tags.contains($0) }
            if !suggestions.isEmpty {
                Text("Existing tags").font(.caption).foregroundStyle(.secondary)
                FlowTags(tags: suggestions, symbol: "plus") { tag in tags.append(tag) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Done") {
                    add()
                    model.setTags(tags, for: wallpaper.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { tags = wallpaper.tags }
    }

    private func add() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        newTag = ""
    }
}

private struct FlowTags: View {
    let tags: [String]
    var symbol = "xmark"
    let action: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button { action(tag) } label: {
                        HStack(spacing: 4) {
                            Text(tag)
                            Image(systemName: symbol).imageScale(.small)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
