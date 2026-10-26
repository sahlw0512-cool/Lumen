import SwiftUI

/// Live resource use, frame-rate limits, and power-saving behavior.
struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var monitor = ResourceMonitor()

    private var settings: Binding<AppSettings> {
        Binding(get: { model.settings }, set: { model.settings = $0 })
    }

    var body: some View {
        Form {
            usageSection
            nowPlayingSection
            frameRateSection
            powerSection
        }
        .formStyle(.grouped)
        .navigationTitle("Performance")
        .navigationSubtitle(model.engine.isAnyPlaying ? "Playing" : "Paused")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: Usage

    private var usageSection: some View {
        Section {
            HStack(spacing: 12) {
                UsageTile(title: "CPU", value: monitor.latest.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—",
                          detail: monitor.impact.map { "\($0.rawValue) impact" } ?? "Measuring…",
                          history: monitor.history.map(\.cpuPercent))
                UsageTile(title: "Memory", value: monitor.latest.map { Format.bytes(Int64($0.memoryBytes)) } ?? "—",
                          detail: "Lumen process", history: monitor.history.map { Double($0.memoryBytes) })
                UsageTile(title: "Energy", value: monitor.latest?.watts.map { String(format: "%.2f W", $0) } ?? "—",
                          detail: monitor.latest?.watts == nil ? "Not reported" : "Average power",
                          history: monitor.history.compactMap(\.watts))
            }
            .padding(.vertical, 4)
        } header: {
            Text("Live Usage")
        } footer: {
            Text("Measured for Lumen's own process every 2 seconds while this page is open. Video decoding runs in macOS's media services, so hardware-decoded video costs a little more than shown; software-decoded codecs cost noticeably more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Now playing

    private var nowPlayingSection: some View {
        Section("Now Playing") {
            if model.displayManager.displays.isEmpty {
                Text("No displays").foregroundStyle(.secondary)
            }
            ForEach(model.displayManager.displays) { display in
                let state = model.engine.displayStates[display.id]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusDot(status: state?.status ?? .empty, pauseReason: state?.pauseReason)
                        Text(display.name).font(.headline)
                        Spacer()
                        Text(StatusDot.label(status: state?.status ?? .empty, pauseReason: state?.pauseReason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let wallpaper = model.assignedWallpaper(for: display) {
                        Text(wallpaper.title).lineLimit(1)
                        HStack(spacing: 6) {
                            let meta = wallpaper.metadata
                            Chip(text: "\(meta.pixelWidth) × \(meta.pixelHeight)")
                            Chip(text: Format.frameRate(meta.frameRate))
                            Chip(text: meta.codecName)
                            Chip(text: meta.isHardwareDecodable ? "Hardware Decode" : "Software Decode",
                                 symbol: meta.isHardwareDecodable ? "cpu" : "exclamationmark.triangle")
                            if meta.isHDR { Chip(text: "HDR") }
                            if let bitrate = Format.bitrate(meta.estimatedBitrate) { Chip(text: bitrate) }
                        }
                        Text(renderingLine(state: state, sourceRate: wallpaper.metadata.frameRate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("System wallpaper — no cost").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func renderingLine(state: WallpaperEngine.DisplayState?, sourceRate: Double?) -> String {
        guard let state, state.wallpaperID != nil else { return "Not loaded" }
        if state.pauseReason != nil { return "Rendering stopped — nothing is decoded while paused" }
        if let cap = state.frameRateCap, sourceRate.map({ $0 > cap + 0.5 }) ?? true {
            return "Rendering at up to \(Int(cap)) fps (limited)"
        }
        return "Rendering at the video's own frame rate"
    }

    // MARK: Frame rate

    private var frameRateSection: some View {
        Section {
            Picker("Maximum frame rate", selection: settings.maxFrameRate) {
                ForEach(FrameRateCap.allCases) { cap in
                    Text(cap.title).tag(cap)
                }
            }
            Toggle(isOn: settings.lowerFrameRateOnBattery) {
                Text("Lower frame rate on battery")
                Text("Keeps the wallpaper moving on battery power, at a lower cost.")
            }
            if model.settings.lowerFrameRateOnBattery {
                Picker("Frame rate on battery", selection: settings.batteryFrameRate) {
                    ForEach(FrameRateCap.allCases.filter { $0 != .native }) { cap in
                        Text(cap.title).tag(cap)
                    }
                }
            }
        } header: {
            Text("Frame Rate")
        } footer: {
            Text("Videos at or below the limit play untouched. Changes apply instantly without restarting playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Power saving

    private enum ReducedBehavior: Hashable {
        case keepPlaying, lowerFrameRate, pause
    }

    private var idleBehavior: Binding<ReducedBehavior> {
        Binding(
            get: {
                if model.settings.pauseWhenIdle { return .pause }
                return model.settings.lowerFrameRateWhenIdle ? .lowerFrameRate : .keepPlaying
            },
            set: { behavior in
                var updated = model.settings
                updated.pauseWhenIdle = behavior == .pause
                updated.lowerFrameRateWhenIdle = behavior == .lowerFrameRate
                model.settings = updated
            }
        )
    }

    private var hiddenBehavior: Binding<ReducedBehavior> {
        Binding(
            get: {
                if model.settings.pauseWhenAppHidden { return .pause }
                return model.settings.lowerFrameRateWhenHidden ? .lowerFrameRate : .keepPlaying
            },
            set: { behavior in
                var updated = model.settings
                updated.pauseWhenAppHidden = behavior == .pause
                updated.lowerFrameRateWhenHidden = behavior == .lowerFrameRate
                model.settings = updated
            }
        )
    }

    private var powerSection: some View {
        Section {
            Picker("When I'm away", selection: idleBehavior) {
                Text("Keep Playing").tag(ReducedBehavior.keepPlaying)
                Text("Lower Frame Rate (\(Int(PlaybackPolicy.reducedFrameRate)) fps)").tag(ReducedBehavior.lowerFrameRate)
                Text("Pause").tag(ReducedBehavior.pause)
            }
            if idleBehavior.wrappedValue != .keepPlaying {
                Stepper(value: settings.idleMinutes, in: 1...240) {
                    LabeledContent("Away after", value: "\(model.settings.idleMinutes) min")
                }
            }
            Picker("When Lumen is hidden", selection: hiddenBehavior) {
                Text("Keep Playing").tag(ReducedBehavior.keepPlaying)
                Text("Lower Frame Rate (\(Int(PlaybackPolicy.reducedFrameRate)) fps)").tag(ReducedBehavior.lowerFrameRate)
                Text("Pause").tag(ReducedBehavior.pause)
            }
            Toggle("Pause when fully covered by windows", isOn: settings.pauseWhenOccluded)
            Toggle("Pause behind fullscreen apps", isOn: settings.pauseWhenFullscreen)
            Toggle("Pause on battery power", isOn: settings.pauseOnBattery)
            Toggle("Pause in Low Power Mode", isOn: settings.pauseInLowPowerMode)
            Toggle("Pause when the Mac is running hot", isOn: settings.pauseUnderThermalPressure)
        } header: {
            Text("Power Saving")
        } footer: {
            Text("A paused wallpaper decodes nothing and uses no GPU time. Sleep, screen lock, and the screen saver always pause playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UsageTile: View {
    let title: String
    let value: String
    let detail: String
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Sparkline(values: history)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let low = values.min(), let high = values.max() else { return path }
        let span = max(high - low, max(high * 0.1, 0.000_001))
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: rect.maxY - rect.height * CGFloat((value - low) / span))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
