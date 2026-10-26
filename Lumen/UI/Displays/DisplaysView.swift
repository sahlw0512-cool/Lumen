import SwiftUI

struct DisplaysView: View {
    @Environment(AppModel.self) private var model
    @State private var highlightedKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.displayManager.displays.isEmpty {
                    ContentUnavailableView("No Displays", systemImage: "display.trianglebadge.exclamationmark",
                                           description: Text("macOS isn't reporting any active displays."))
                } else {
                    ArrangementMap(highlightedKey: $highlightedKey)
                        .frame(height: 200)
                        .padding(18)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))

                    StudioPanel()

                    ForEach(model.displayManager.displays) { display in
                        DisplayCard(display: display, isHighlighted: highlightedKey == display.id)
                            .onHover { highlightedKey = $0 ? display.id : nil }
                    }
                }

                if !model.rememberedDisplays.isEmpty {
                    rememberedSection
                }

                Text("Each display keeps its own wallpaper, scaling, and position. Lumen remembers these for displays that are disconnected and restores them automatically when they return, along with which display plays audio. New displays start with the most recently applied wallpaper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.contentPadding)
        }
        .navigationTitle("Displays")
        .navigationSubtitle(model.displayManager.displays.count == 1 ? "1 connected" : "\(model.displayManager.displays.count) connected")
    }

    private var rememberedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remembered Displays")
                .font(.headline)
            ForEach(model.rememberedDisplays) { entry in
                HStack {
                    Image(systemName: "display")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.assignment.displayName)
                        Text(model.wallpaper(id: entry.assignment.wallpaperID)?.title ?? "No wallpaper")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { model.forgetDisplay(entry.id) }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Miniature of the display arrangement from System Settings, with each
/// display showing its current wallpaper.
struct ArrangementMap: View {
    @Environment(AppModel.self) private var model
    @Binding var highlightedKey: String?

    var body: some View {
        GeometryReader { proxy in
            let displays = model.displayManager.displays
            let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min(proxy.size.width / max(union.width, 1), proxy.size.height / max(union.height, 1)) * 0.94
            let offsetX = (proxy.size.width - union.width * scale) / 2
            let offsetY = (proxy.size.height - union.height * scale) / 2

            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let rect = CGRect(
                        x: offsetX + (display.frame.minX - union.minX) * scale,
                        // AppKit's origin is bottom-left; SwiftUI's is top-left.
                        y: offsetY + (union.maxY - display.frame.maxY) * scale,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    )
                    miniDisplay(display, union: union, scale: scale)
                        .frame(width: max(rect.width - 4, 1), height: max(rect.height - 4, 1))
                        .offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .animation(.smooth, value: model.displayManager.displays)
    }

    private func miniDisplay(_ display: DisplayInfo, union: CGRect, scale: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if model.isSpanning, let wallpaper = model.assignedWallpaper(for: display) {
                // One thumbnail across the whole arrangement, cropped per display.
                ThumbnailImage(wallpaper: wallpaper)
                    .frame(width: union.width * scale, height: union.height * scale)
                    .offset(x: -(display.frame.minX - union.minX) * scale,
                            y: -(union.maxY - display.frame.maxY) * scale)
                    .frame(width: display.frame.width * scale, height: display.frame.height * scale, alignment: .topLeading)
                    .clipped()
            } else if let wallpaper = model.assignedWallpaper(for: display) {
                ThumbnailImage(wallpaper: wallpaper)
            } else {
                Rectangle().fill(Theme.placeholderGradient)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 4) {
                if display.isMain { Image(systemName: "menubar.rectangle") }
                Text(display.name).lineLimit(1)
                if model.audioDisplay?.id == display.id && model.settings.audioEnabled {
                    Image(systemName: "speaker.wave.2.fill")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(highlightedKey == display.id ? Color.accentColor : Color.white.opacity(0.25),
                              lineWidth: highlightedKey == display.id ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .onHover { highlightedKey = $0 ? display.id : nil }
    }
}

struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    let display: DisplayInfo
    let isHighlighted: Bool

    private var state: WallpaperEngine.DisplayState? { model.engine.displayStates[display.id] }
    private var assigned: Wallpaper? { model.assignedWallpaper(for: display) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let assigned {
                    ThumbnailImage(wallpaper: assigned)
                } else {
                    ZStack {
                        Rectangle().fill(Theme.placeholderGradient)
                        Text("System Wallpaper").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: 176, height: 176 / max(display.aspectRatio, 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(display.name).font(.headline)
                    if display.isMain { Chip(text: "Main") }
                    if display.isBuiltIn { Chip(text: "Built-in") }
                    if display.supportsEDR { Chip(text: "EDR") }
                    if model.isSpanning { Chip(text: "Spanned", symbol: "rectangle.split.3x1", prominent: true) }
                    if model.audioDisplay?.id == display.id { Chip(text: "Audio", symbol: "speaker.wave.2.fill") }
                }
                Text(specLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let state {
                    HStack(spacing: 6) {
                        StatusDot(status: state.status, pauseReason: state.pauseReason)
                        Text(StatusDot.label(status: state.status, pauseReason: state.pauseReason))
                            .lineLimit(2)
                    }
                    .font(.caption)
                }

                HStack(spacing: 12) {
                    Picker("Wallpaper", selection: Binding<UUID?>(
                        get: { model.assignments[display.id]?.wallpaperID },
                        set: { newValue in
                            if let newValue {
                                model.apply(newValue, to: display.id)
                            } else {
                                model.clearWallpaper(on: display.id)
                            }
                        }
                    )) {
                        Text("System Wallpaper").tag(UUID?.none)
                        Divider()
                        ForEach(model.availableWallpapers) { wallpaper in
                            Text(wallpaper.title).tag(UUID?.some(wallpaper.id))
                        }
                    }
                    .frame(maxWidth: 280)

                    Picker("Scaling", selection: Binding<ScalingMode?>(
                        get: { model.assignments[display.id]?.scaling },
                        set: { model.setScaling($0, for: display.id) }
                    )) {
                        Text("Default (\(model.settings.defaultScaling.title))").tag(ScalingMode?.none)
                        Divider()
                        ForEach(ScalingMode.allCases) { mode in
                            Text(mode.title).tag(ScalingMode?.some(mode))
                        }
                    }
                    .frame(maxWidth: 220)

                    PositionButton(position: model.position(for: display.id)) { position, persist in
                        model.setPosition(position, for: display.id, persist: persist)
                    }
                }
                .disabled(model.isSpanning)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: isHighlighted ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }

    private var specLine: String {
        var parts = ["\(display.pixelsLabel) pixels", display.pointsLabel]
        if let hz = Format.refreshRate(display.refreshRate) { parts.append(hz) }
        if display.rotation != 0 { parts.append("Rotated \(Int(display.rotation))°") }
        return parts.joined(separator: " · ")
    }
}

/// Span mode, audio routing, and the spanned wallpaper's framing.
private struct StudioPanel: View {
    @Environment(AppModel.self) private var model
    @State private var spanChoice: UUID?

    private var displayCount: Int { model.displayManager.displays.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Layout").font(.headline)
                Spacer()
                Picker("Layout", selection: Binding(
                    get: { model.isSpanning },
                    set: { spanning in
                        if spanning {
                            if let id = spanChoice ?? model.lastAppliedWallpaperID ?? model.availableWallpapers.first?.id {
                                model.startSpan(id)
                            }
                        } else {
                            model.stopSpan()
                        }
                    }
                )) {
                    Label("Separate", systemImage: "rectangle.grid.1x2").tag(false)
                    Label("Span", systemImage: "rectangle.split.3x1").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.availableWallpapers.isEmpty)
            }

            if let span = model.span {
                HStack(spacing: 12) {
                    Picker("Wallpaper", selection: Binding(
                        get: { span.wallpaperID },
                        set: { model.startSpan($0) }
                    )) {
                        ForEach(model.availableWallpapers) { wallpaper in
                            Text(wallpaper.title).tag(wallpaper.id)
                        }
                    }
                    .frame(maxWidth: 280)

                    Picker("Scaling", selection: Binding(
                        get: { span.scaling },
                        set: { model.setSpanScaling($0) }
                    )) {
                        ForEach(ScalingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(maxWidth: 200)

                    PositionButton(position: span.position ?? .centered) { position, persist in
                        model.setSpanPosition(position, persist: persist)
                    }
                }
                Text(displayCount > 1
                     ? "One video stretches across all \(displayCount) displays as arranged in System Settings, kept in sync frame by frame."
                     : "Connect another display to see the video stretch across both. Spanning stays on and resumes when it's connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Each display shows its own wallpaper. Choose Span to stretch one video across every display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Label("Play audio on", systemImage: "speaker.wave.2")
                Spacer()
                Picker("Play audio on", selection: Binding<String?>(
                    get: { model.audioDisplayKey },
                    set: { model.setAudioDisplay($0) }
                )) {
                    Text("Main Display").tag(String?.none)
                    Divider()
                    ForEach(model.displayManager.displays) { display in
                        Text(display.name).tag(String?.some(display.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            if !model.settings.audioEnabled && !model.wallpapers.contains(where: { !$0.soundtracks.isEmpty }) {
                Text("Wallpaper audio is off. Turn it on in Settings or with the volume control in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .onAppear { spanChoice = model.span?.wallpaperID }
    }
}

/// Opens the framing controls for a display (or the spanned wallpaper).
struct PositionButton: View {
    let position: ContentPosition
    /// `persist` is false while a slider is being dragged.
    let onChange: (ContentPosition, Bool) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Position", systemImage: position.isCentered ? "viewfinder" : "viewfinder.rectangular")
        }
        .help("Zoom and pan the video on this display")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PositionEditor(position: position, onChange: onChange)
        }
    }
}

private struct PositionEditor: View {
    let position: ContentPosition
    let onChange: (ContentPosition, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Position").font(.headline)
            slider("Zoom", value: \.zoom, in: 1...3, label: "\(Int((position.zoom * 100).rounded()))%")
            slider("Horizontal", value: \.offsetX, in: -1...1, label: edgeLabel(position.offsetX, low: "Left", high: "Right"))
            slider("Vertical", value: \.offsetY, in: -1...1, label: edgeLabel(position.offsetY, low: "Bottom", high: "Top"))
            Text("Panning moves the part of the video that's cropped off screen, or the letterboxed video when using Fit. Zoom in to pan a video that already fits exactly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Reset") { onChange(.centered, true) }
                    .disabled(position.isCentered)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func slider(_ title: String, value keyPath: WritableKeyPath<ContentPosition, Double>,
                        in range: ClosedRange<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            Slider(value: Binding(
                get: { position[keyPath: keyPath] },
                set: { newValue in
                    var updated = position
                    updated[keyPath: keyPath] = newValue
                    onChange(updated, false)
                }
            ), in: range) { editing in
                if !editing { onChange(position, true) }
            }
        }
    }

    private func edgeLabel(_ value: Double, low: String, high: String) -> String {
        if abs(value) < 0.01 { return "Center" }
        return "\(Int((abs(value) * 100).rounded()))% \(value < 0 ? low : high)"
    }
}
