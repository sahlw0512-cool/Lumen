import AppKit
import SwiftUI

/// Live, non-destructive wallpaper effects. Everything applies instantly to
/// every display and never touches the original video files.
struct EffectsView: View {
    @Environment(AppModel.self) private var model

    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var effects: Binding<WallpaperEffects> {
        Binding(get: { model.settings.effects }, set: { model.settings.effects = $0 })
    }

    private var scopedWallpaper: Wallpaper? { model.wallpaper(id: model.effectsScope) }

    /// Picture adjustments for the wallpaper being edited, or for all wallpapers.
    private var adjustments: Binding<WallpaperEffects> {
        Binding(
            get: { scopedWallpaper?.effects ?? model.settings.effects },
            set: { newValue in
                if let wallpaper = scopedWallpaper {
                    model.setEffects(newValue, for: wallpaper.id)
                } else {
                    model.settings.effects = newValue
                }
            }
        )
    }

    var body: some View {
        Form {
            scopeSection
            adjustmentsSection
            appearanceSection
            motionSection
            clockSection
            AudioReactiveSection(effects: effects)
        }
        .formStyle(.grouped)
        .navigationTitle("Effects")
        .navigationSubtitle(scopedWallpaper.map { "Editing “\($0.title)”" } ?? "Applied live to every display")
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.saveEffectPreset(named: presetName, effects: adjustments.wrappedValue) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current picture adjustments.")
        }
    }

    private var scopeSection: some View {
        Section {
            Picker("Editing", selection: Bindable(model).effectsScope) {
                Text("All Wallpapers").tag(UUID?.none)
                Divider()
                ForEach(model.availableWallpapers) { wallpaper in
                    Text(wallpaper.effects == nil ? wallpaper.title : "\(wallpaper.title) (custom)").tag(UUID?.some(wallpaper.id))
                }
            }
            if let wallpaper = scopedWallpaper, wallpaper.effects != nil {
                HStack {
                    Text("This wallpaper has its own adjustments.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Use the Global Effects") { model.setEffects(nil, for: wallpaper.id) }
                }
            }
            LabeledContent("Presets") {
                HStack {
                    Menu("Apply") {
                        ForEach(model.allEffectPresets) { preset in
                            Button(preset.name) { model.applyEffectPreset(preset, to: scopedWallpaper?.id) }
                        }
                    }
                    .fixedSize()
                    Button("Save Current…") {
                        presetName = ""
                        isNamingPreset = true
                    }
                    if !model.settings.effectPresets.isEmpty {
                        Menu("Delete") {
                            ForEach(model.settings.effectPresets) { preset in
                                Button(preset.name, role: .destructive) { model.deleteEffectPreset(preset.id) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        } footer: {
            Text("Picture adjustments can be set for all wallpapers or per wallpaper. Dark Mode, motion, clock, and audio settings always apply to all.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Sections

    private var adjustmentsSection: some View {
        Section {
            EffectSlider(title: "Blur", value: adjustments.blur, range: 0...40, format: { "\(Int($0.rounded())) pt" })
            EffectSlider(title: "Brightness", value: adjustments.brightness, range: -0.5...0.5, format: Self.signedPercent)
            EffectSlider(title: "Contrast", value: adjustments.contrast, range: 0.5...1.5, format: { Self.signedPercent($0 - 1) })
            EffectSlider(title: "Saturation", value: adjustments.saturation, range: 0...2, format: { Self.signedPercent($0 - 1) })
            LabeledContent("Color Tint") {
                HStack(spacing: 10) {
                    ColorPicker("Tint color", selection: Binding(
                        get: { Color(red: adjustments.wrappedValue.tint.red, green: adjustments.wrappedValue.tint.green, blue: adjustments.wrappedValue.tint.blue) },
                        set: { adjustments.wrappedValue.tint = RGBColor($0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    Slider(value: adjustments.tintAmount, in: 0...1)
                        .frame(maxWidth: 200)
                    Text("\(Int((adjustments.wrappedValue.tintAmount * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            EffectSlider(title: "Vignette", value: adjustments.vignette, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
        } header: {
            HStack {
                Text(scopedWallpaper == nil ? "Adjustments" : "Adjustments for This Wallpaper")
                Spacer()
                Button("Reset") { adjustments.wrappedValue.resetAdjustments() }
                    .controlSize(.small)
                    .disabled(!adjustments.wrappedValue.needsFilters && adjustments.wrappedValue.vignette == 0)
            }
        } footer: {
            Text("Blur, brightness, contrast, saturation, and tint use the GPU while active. Vignette is nearly free.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section("Dark Mode") {
            Toggle(isOn: effects.dimInDarkMode) {
                Text("Darken wallpapers in Dark Mode")
                Text("Follows the system appearance and switches automatically, including with Auto appearance.")
            }
            if model.settings.effects.dimInDarkMode {
                EffectSlider(title: "Darken by", value: effects.darkModeDim, range: 0.05...0.8, format: { "\(Int(($0 * 100).rounded()))%" })
            }
        }
    }

    private var motionSection: some View {
        Section("Motion") {
            Toggle(isOn: effects.parallax) {
                Text("Parallax")
                Text("The wallpaper shifts gently as you move the pointer, like looking through a window.")
            }
            if model.settings.effects.parallax {
                EffectSlider(title: "Depth", value: effects.parallaxAmount, range: 0.1...1, format: { "\(Int(($0 * 100).rounded()))%" })
            }
        }
    }

    private var clockSection: some View {
        Section("Clock") {
            Toggle("Show clock on the desktop", isOn: effects.clock.enabled)
            if model.settings.effects.clock.enabled {
                Toggle("Show date", isOn: effects.clock.showDate)
                Picker("Position", selection: effects.clock.position) {
                    ForEach(ClockPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                EffectSlider(title: "Size", value: effects.clock.size, range: 0.4...2.5, format: { "\(Int(($0 * 100).rounded()))%" })
                Toggle("Show on all displays", isOn: effects.clock.onAllDisplays)
            }
        }
    }

    private static func signedPercent(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }
}

private struct AudioReactiveSection: View {
    @Environment(AppModel.self) private var model
    @Binding var effects: WallpaperEffects

    private var audio: AudioLevelMonitor { model.engine.effects.audio }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { effects.audioReactive },
                set: { enable in
                    guard enable else {
                        effects.audioReactive = false
                        return
                    }
                    switch AudioLevelMonitor.currentPermission() {
                    case .granted:
                        effects.audioReactive = true
                    case .notDetermined:
                        Task {
                            if await audio.requestPermission() { effects.audioReactive = true }
                        }
                    case .denied:
                        effects.audioReactive = false
                    }
                }
            )) {
                Text("Audio-reactive")
                Text("The wallpaper pulses with sound picked up by your audio input. Lumen asks for microphone permission first; audio is reduced to a loudness level in memory and never recorded, stored, or sent anywhere.")
            }
            .disabled(audio.permission == .denied)

            if audio.permission == .denied {
                HStack {
                    Label("Microphone access is off for Lumen.", systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            if effects.audioReactive {
                EffectSlider(title: "Intensity", value: $effects.audioReactiveIntensity, range: 0.1...1,
                             format: { "\(Int(($0 * 100).rounded()))%" })
                LabeledContent("Input level") {
                    HStack(spacing: 8) {
                        ProgressView(value: audio.level)
                            .frame(maxWidth: 200)
                        Text(audio.isRunning ? "Listening" : "Waiting for playback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("To react to music playing on this Mac rather than the room, choose a loopback audio device as the input in System Settings › Sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A labeled slider with a value readout.
struct EffectSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(maxWidth: 240)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

extension RGBColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}
