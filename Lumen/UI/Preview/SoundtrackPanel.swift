import SwiftUI
import UniformTypeIdentifiers

/// Lists the audio files attached to a wallpaper and lets the user add,
/// rename, reorder, and remove them.
struct SoundtrackPanel: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    @State private var isImporterPresented = false
    @State private var editing: Soundtrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Soundtracks", systemImage: "music.note.list")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Add Audio…", systemImage: "plus")
                }
                .help("Add one or more audio files to play with this wallpaper")
            }

            if wallpaper.soundtracks.isEmpty {
                Text("Add audio files to play with this wallpaper. They play in order and loop on your main display, and pause whenever the wallpaper pauses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(wallpaper.soundtracks.enumerated()), id: \.element.id) { index, track in
                            row(track, index: index)
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(item: $editing) { track in
            RenameSoundtrackSheet(track: track) { title, artist in
                model.editSoundtrackInfo(track.id, in: wallpaper.id, title: title, artist: artist)
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                model.addSoundtracks(urls, to: wallpaper.id)
            case .failure(let error):
                Log.warning("Audio open panel failed: \(error.localizedDescription)", category: "audio")
            }
        }
    }

    private var summary: String {
        let tracks = wallpaper.soundtracks
        guard !tracks.isEmpty else { return "" }
        let count = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
        let total = tracks.compactMap(\.duration).reduce(0, +)
        return total > 0 ? "\(count) · \(Format.time(total))" : count
    }

    private func row(_ track: Soundtrack, index: Int) -> some View {
        let isMissing = model.resolvedURL(for: track) == nil
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "music.note")
                .foregroundStyle(isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { editing = track }
            .help(isMissing ? "File not found: \(track.originalPath)" : "\(track.originalPath)\nDouble-click to rename")
            Spacer()
            Button {
                editing = track
            } label: {
                Image(systemName: "pencil")
            }
            .help("Rename")
            if let duration = track.duration {
                Text(Format.time(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                model.moveSoundtrack(track.id, in: wallpaper.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move up")
            Button {
                model.moveSoundtrack(track.id, in: wallpaper.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == wallpaper.soundtracks.count - 1)
            .help("Move down")
            Button {
                model.removeSoundtrack(track.id, from: wallpaper.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Remove from this wallpaper (the file is kept)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Gives a track a name of the user's choosing; the file itself isn't renamed.
private struct RenameSoundtrackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: Soundtrack
    let save: (String, String) -> Void
    @State private var title = ""
    @State private var artist = ""

    private var fileName: String {
        URL(fileURLWithPath: track.originalPath).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Track").font(.headline)
            Form {
                TextField("Name", text: $title, prompt: Text(fileName))
                TextField("Artist", text: $artist, prompt: Text("Optional"))
            }
            Text(track.originalPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save(title, artist)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            title = track.title
            artist = track.artist ?? ""
        }
    }
}
