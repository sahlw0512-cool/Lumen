import SwiftUI

struct PreviewView: View {
    @Environment(AppModel.self) private var model
    let wallpaperID: UUID

    @State private var preview = PreviewPlayerModel()
    @State private var scaling: ScalingMode = .fill
    @State private var stageDisplayKey: String?

    var body: some View {
        Group {
            if let wallpaper = model.wallpaper(id: wallpaperID) {
                content(for: wallpaper)
            } else {
                ContentUnavailableView("Wallpaper Unavailable", systemImage: "film",
                                       description: Text("This item is no longer in your library."))
            }
        }
        .navigationTitle(model.wallpaper(id: wallpaperID)?.title ?? "Preview")
        .onAppear(perform: start)
        .onDisappear { preview.teardown() }
    }

    private var stageDisplay: DisplayInfo? {
        let displays = model.displayManager.displays
        return displays.first { $0.id == stageDisplayKey } ?? displays.first(where: \.isMain) ?? displays.first
    }

    private func start() {
        scaling = model.settings.defaultScaling
        guard let wallpaper = model.wallpaper(id: wallpaperID), let url = model.resolvedURL(for: wallpaper) else { return }
        preview.load(url: url, knownDuration: wallpaper.metadata.duration)
    }

    private func content(for wallpaper: Wallpaper) -> some View {
        VStack(spacing: 18) {
            header(for: wallpaper)
            stage
            controls(for: wallpaper)
            WallpaperToolsPanel(wallpaper: wallpaper, preview: preview)
            SoundtrackPanel(wallpaper: wallpaper)
        }
        .padding(Theme.contentPadding)
    }

    private func header(for wallpaper: Wallpaper) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                model.previewWallpaperID = nil
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to Library (Esc)")

            VStack(alignment: .leading, spacing: 4) {
                Text(wallpaper.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: wallpaper.metadata.resolutionLabel)
                    Chip(text: wallpaper.metadata.dimensionsLabel)
                    Chip(text: wallpaper.metadata.aspectLabel)
                    Chip(text: Format.frameRate(wallpaper.metadata.frameRate) + (wallpaper.metadata.isVariableFrameRate ? " VFR" : ""))
                    Chip(text: wallpaper.metadata.codecName)
                    if wallpaper.metadata.isHDR { Chip(text: "HDR") }
                    if let bitrate = Format.bitrate(wallpaper.metadata.estimatedBitrate) { Chip(text: bitrate) }
                    if let size = wallpaper.metadata.fileSize { Chip(text: Format.bytes(size)) }
                    Chip(text: wallpaper.metadata.isHardwareDecodable ? "Hardware Decode" : "Software Decode",
                         symbol: wallpaper.metadata.isHardwareDecodable ? "bolt.fill" : "cpu")
                }
            }
            Spacer()
            if model.displayManager.displays.count > 1 {
                Picker("Preview on", selection: Binding(
                    get: { stageDisplay?.id ?? "" },
                    set: { stageDisplayKey = $0 }
                )) {
                    ForEach(model.displayManager.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .frame(maxWidth: 240)
                .help("Shape the preview like this display")
            }
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            PlayerSurface(player: preview.player, gravity: scaling.videoGravity)
            if let error = preview.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).foregroundStyle(.white)
                }
            }
        }
        .aspectRatio(stageDisplay?.aspectRatio ?? 16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { preview.togglePlay() }
    }

    private func controls(for wallpaper: Wallpaper) -> some View {
        HStack(spacing: 14) {
            Button {
                preview.togglePlay()
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(preview.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text(Format.time(preview.currentTime))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            if preview.isPreviewingLoop {
                Label("Previewing the loop point", systemImage: "repeat")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Slider(
                    value: Binding(get: { min(preview.currentTime, max(preview.duration, 0.01)) },
                                   set: { preview.scrub(to: $0) }),
                    in: 0...max(preview.duration, 0.01),
                    onEditingChanged: { editing in editing ? preview.beginScrub() : preview.endScrub() }
                )
                .controlSize(.small)
            }

            Text(Format.time(preview.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            if wallpaper.metadata.hasAudio {
                Button {
                    preview.isMuted.toggle()
                } label: {
                    Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(preview.isMuted ? "Unmute preview" : "Mute preview")
                Slider(value: Bindable(preview).volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 80)
                    .disabled(preview.isMuted)
            }

            Picker("Scaling", selection: $scaling) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.title).tag(mode).help(mode.detail)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            applyControl(for: wallpaper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func applyControl(for wallpaper: Wallpaper) -> some View {
        let displays = model.displayManager.displays
        HStack(spacing: 4) {
            Button {
                model.apply(wallpaper.id, scaling: scaling)
            } label: {
                Label("Set as Wallpaper", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Apply to all displays (⌘↩)")

            if displays.count > 1 {
                Menu {
                    ForEach(displays) { display in
                        Button("Set on \(display.name)") {
                            model.apply(wallpaper.id, to: display.id, scaling: scaling)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a display")
            }
        }
    }
}
