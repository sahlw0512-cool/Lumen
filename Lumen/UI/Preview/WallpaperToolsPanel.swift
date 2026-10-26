import SwiftUI

/// Per-wallpaper tools under the preview: lock screen frame, loop trimming
/// and crossfade, and this wallpaper's own effects.
struct WallpaperToolsPanel: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let preview: PreviewPlayerModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            lockScreenGroup
            loopGroup
            effectsGroup
        }
    }

    // MARK: Lock screen & screen saver

    private var lockScreenGroup: some View {
        ToolGroup(title: "Lock Screen & Login", symbol: "lock.display") {
            HStack(spacing: 10) {
                PosterThumbnail(wallpaper: wallpaper)
                    .frame(width: 96, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaper.posterTime.map { "Frame at \(Format.time($0))" } ?? "First frame")
                        .font(.callout)
                    Text(model.settings.syncStaticDesktopPicture ? "Shown on the lock screen and login window" : "Turn on in Settings to use it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Use Current Frame") {
                    model.setPosterTime(preview.currentTime, for: wallpaper.id)
                }
                .disabled(preview.isPreviewingLoop)
                .help("Pause on the frame you like, then click")
                if wallpaper.posterTime != nil {
                    Button("Reset") { model.setPosterTime(nil, for: wallpaper.id) }
                }
            }
            HStack {
                Button("Save Frame for Screen Saver…") {
                    model.exportFrame(of: wallpaper.id, at: preview.isPreviewingLoop ? (wallpaper.posterTime ?? 0) : preview.currentTime)
                }
                if !model.settings.syncStaticDesktopPicture {
                    Button("Turn On") { model.settings.syncStaticDesktopPicture = true }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Loop

    private var loopGroup: some View {
        let duration = wallpaper.metadata.duration
        let range = wallpaper.loopRange ?? 0...duration
        return ToolGroup(title: "Loop", symbol: "repeat") {
            HStack {
                Text("Start \(Format.time(range.lowerBound))").monospacedDigit()
                Button("Set") { setLoop(start: preview.currentTime, end: wallpaper.trimEnd) }
                    .disabled(preview.isPreviewingLoop)
                Spacer()
                Text("End \(Format.time(range.upperBound))").monospacedDigit()
                Button("Set") { setLoop(start: wallpaper.trimStart, end: preview.currentTime) }
                    .disabled(preview.isPreviewingLoop)
            }
            .font(.callout)
            .controlSize(.small)
            LoopRangeBar(duration: duration, range: range, playhead: preview.isPreviewingLoop ? nil : preview.currentTime)
                .frame(height: 8)
            HStack {
                Text("Crossfade")
                Slider(value: Binding(
                    get: { wallpaper.loopCrossfade },
                    set: { model.setLoop(start: wallpaper.trimStart, end: wallpaper.trimEnd, crossfade: ($0 * 4).rounded() / 4, for: wallpaper.id) }
                ), in: 0...3)
                Text(wallpaper.loopCrossfade > 0 ? String(format: "%.2g s", wallpaper.loopCrossfade) : "Off")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.callout)
            HStack {
                Button(preview.isPreviewingLoop ? "Stop Loop Preview" : "Preview Loop") {
                    if preview.isPreviewingLoop {
                        preview.showSource(at: range.lowerBound)
                    } else {
                        preview.previewLoop(LoopSettings(range: wallpaper.loopRange, crossfade: wallpaper.loopCrossfade))
                    }
                }
                .help("Plays the loop point as the desktop will")
                if wallpaper.loopRange != nil || wallpaper.loopCrossfade > 0 {
                    Button("Reset") { model.setLoop(start: nil, end: nil, crossfade: 0, for: wallpaper.id) }
                }
            }
            .controlSize(.small)
        }
    }

    private func setLoop(start: Double?, end: Double?) {
        model.setLoop(start: start, end: end, crossfade: wallpaper.loopCrossfade, for: wallpaper.id)
    }

    // MARK: Effects

    private var effectsGroup: some View {
        ToolGroup(title: "Effects", symbol: "camera.filters") {
            Toggle("Use its own effects", isOn: Binding(
                get: { wallpaper.effects != nil },
                set: { custom in model.setEffects(custom ? model.settings.effects : nil, for: wallpaper.id) }
            ))
            Text(wallpaper.effects == nil ? "Uses the effects set for all wallpapers." : "Overrides the global picture adjustments.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Menu("Apply Preset") {
                    ForEach(model.allEffectPresets) { preset in
                        Button(preset.name) { model.applyEffectPreset(preset, to: wallpaper.id) }
                    }
                }
                .fixedSize()
                Button("Edit…") {
                    model.effectsScope = wallpaper.id
                    model.sidebarSelection = .effects
                    model.previewWallpaperID = nil
                }
            }
            .controlSize(.small)
        }
    }
}

private struct ToolGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The chosen lock-screen frame, rendered from the video.
private struct PosterThumbnail: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.placeholderGradient)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: wallpaper.posterTime) {
            guard let url = model.resolvedURL(for: wallpaper) else { return }
            let access = ScopedFileAccess(url: url)
            image = try? await model.thumbnails.frame(from: url, atSeconds: wallpaper.posterTime ?? 0,
                                                      maximumSize: CGSize(width: 320, height: 320), exact: true)
            withExtendedLifetime(access) {}
        }
    }
}

/// The trimmed range drawn over the full length, with the playhead.
private struct LoopRangeBar: View {
    let duration: Double
    let range: ClosedRange<Double>
    let playhead: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = duration > 0 ? width / duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.7))
                    .frame(width: max((range.upperBound - range.lowerBound) * scale, 2))
                    .offset(x: range.lowerBound * scale)
                if let playhead {
                    Rectangle().fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: min(max(playhead * scale - 1, 0), width - 2))
                }
            }
        }
    }
}
