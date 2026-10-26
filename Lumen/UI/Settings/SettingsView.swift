import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let isEmbedded: Bool

    @State private var loginError: String?
    @State private var confirmReset = false
    @State private var thumbnailUsage: Int64 = 0

    var body: some View {
        @Bindable var model = model
        Form {
            generalSection(settings: $model.settings)
            playbackSection(settings: $model.settings)
            lockScreenSection(settings: $model.settings)
            audioSection(settings: $model.settings)
            energySection(settings: $model.settings)
            shortcutsSection(settings: $model.settings)
            syncSection(settings: $model.settings)
            updatesSection
            librarySection
            resetSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { refreshUsage() }
        .alert("Launch at Login", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
        .confirmationDialog("Reset all preferences to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Preferences", role: .destructive) { model.resetPreferences() }
        } message: {
            Text("Your library and per-display wallpapers are kept.")
        }
    }

    // MARK: Sections

    private func generalSection(settings: Binding<AppSettings>) -> some View {
        Section("General") {
            Toggle(isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { enabled in
                    do { try model.launchAtLogin.setEnabled(enabled) } catch { loginError = error.localizedDescription }
                }
            )) {
                Text("Open Lumen at login")
                if model.launchAtLogin.requiresApproval {
                    Text("Approval needed in System Settings → General → Login Items.")
                }
            }
            if model.launchAtLogin.requiresApproval {
                Button("Open Login Items Settings…") { model.launchAtLogin.openSystemSettings() }
            }
            Toggle("Show in menu bar", isOn: settings.showMenuBarItem)
                .disabled(!model.settings.showInDock)
            Toggle(isOn: settings.showInDock) {
                Text("Show in Dock")
                Text("When hidden, Lumen stays reachable from the menu bar.")
            }
            Picker("Appearance", selection: settings.appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private func playbackSection(settings: Binding<AppSettings>) -> some View {
        Section {
            Picker("Default scaling", selection: settings.defaultScaling) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("When the video ends", selection: settings.loopMode) {
                ForEach(LoopMode.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Playback speed") {
                HStack {
                    Slider(value: settings.playbackRate, in: 0.25...2, step: 0.25)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2g×", model.settings.playbackRate))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Toggle("Crossfade when changing wallpapers", isOn: settings.crossfadeTransitions)
            Toggle(isOn: settings.hideDesktopIcons) {
                Text("Hide desktop icons")
                Text("Draws the wallpaper over Finder's desktop icons. Your files stay on the desktop and reappear when this is off.")
            }
            Toggle(isOn: settings.warnAboutSoftwareDecoding) {
                Text("Warn about software-decoded videos")
                Text("Videos your Mac can't decode in hardware (for example AV1 on older Macs) use much more CPU and battery.")
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Videos play at their original resolution, frame rate, and color (including HDR on capable displays). Lumen never transcodes or copies your files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func lockScreenSection(settings: Binding<AppSettings>) -> some View {
        Section {
            Toggle(isOn: settings.syncStaticDesktopPicture) {
                Text("Use a frame for the lock screen and login window")
                Text("Sets a full-resolution frame of each wallpaper as the macOS picture, which the lock screen, login window, Mission Control, and Space transitions show.")
            }
            if model.settings.syncStaticDesktopPicture {
                Picker(selection: settings.lockScreenFrame) {
                    ForEach(LockScreenFrame.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Lock screen shows")
                    Text(model.settings.lockScreenFrame == .latest
                         ? "The exact frame on screen when you lock, sleep, or the screen saver starts. The video carries on from it when you come back."
                         : "The frame picked in each wallpaper's preview.")
                }
                Toggle(isOn: settings.keepLockScreenPictureAfterQuit) {
                    Text("Keep it after Lumen quits")
                    Text("Needed for the login window after you log out or restart. Turn off to put your original picture back whenever Lumen quits.")
                }
            }
            if model.hasSavedDesktopPictures && !model.settings.syncStaticDesktopPicture {
                Button("Restore Original Desktop Pictures") { model.restoreOriginalDesktopPictures() }
            }
        } header: {
            Text("Lock Screen & Login Window")
        } footer: {
            Text("macOS has no setting apps can use for the screen saver. To use a frame there, open a wallpaper's preview, choose Save Frame for Screen Saver, then pick that folder in System Settings › Screen Saver.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutsSection(settings: Binding<AppSettings>) -> some View {
        Section {
            Toggle(isOn: settings.globalHotkeysEnabled) {
                Text("Global keyboard shortcuts")
                Text("Work from any app, without Accessibility permission.")
            }
            if model.settings.globalHotkeysEnabled {
                ForEach(GlobalHotkeys.Action.allCases, id: \.rawValue) { action in
                    LabeledContent(action.title) {
                        Text(action.displayString).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Keyboard Shortcuts")
        } footer: {
            Text("Lumen's actions are also available in the Shortcuts app and as Focus filters (System Settings › Focus › Focus Filters).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func syncSection(settings: Binding<AppSettings>) -> some View {
        Section {
            Toggle(isOn: settings.iCloudSyncEnabled) {
                Text("Sync with iCloud")
                Text("Effects, presets, favorites, tags, and playlists. Videos stay on each Mac; items are matched by file name.")
            }
            switch model.cloudSync.status {
            case .off:
                EmptyView()
            case .unavailable:
                Label("iCloud isn't available to this build. Add the iCloud capability (Key-value storage) to the Lumen target in Xcode, and sign in to iCloud.", systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                Label("Waiting for changes", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .synced(let date):
                Label("Synced \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Sync")
        }
    }

    private func audioSection(settings: Binding<AppSettings>) -> some View {
        Section("Audio") {
            Toggle(isOn: settings.audioEnabled) {
                Text("Play wallpaper audio")
                Text("Only the main display's wallpaper plays sound. Off by default. Soundtracks you add to a wallpaper always play, in place of the video's own audio.")
            }
            LabeledContent("Volume") {
                Slider(value: settings.audioVolume, in: 0...1)
                    .frame(maxWidth: 220)
            }
            .disabled(!model.settings.audioEnabled && !model.wallpapers.contains { !$0.soundtracks.isEmpty })
        }
    }

    private var updatesSection: some View {
        @Bindable var updates = model.updates
        return Section("Updates") {
            LabeledContent("Version", value: UpdateChecker.currentVersion)
            if updates.isConfigured {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                HStack {
                    Button("Check Now") { updates.checkNow() }
                        .disabled(updates.state == .checking)
                    switch updates.state {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .available(let release):
                        Button("Download \(release.version)") { updates.download(release) }
                    case .upToDate:
                        Text("Up to date").foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message).foregroundStyle(.secondary)
                    case .idle:
                        if let checked = updates.lastChecked {
                            Text("Last checked \(checked.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Update checks aren't set up in this build.").foregroundStyle(.secondary)
            }
        }
    }

    private func energySection(settings: Binding<AppSettings>) -> some View {
        Section {
            Toggle("Pause on battery power", isOn: settings.pauseOnBattery)
            Toggle("Pause in Low Power Mode", isOn: settings.pauseInLowPowerMode)
            Toggle("Pause when the Mac is running hot", isOn: settings.pauseUnderThermalPressure)
            Toggle("Pause behind fullscreen apps", isOn: settings.pauseWhenFullscreen)
            Toggle("Pause when fully covered by windows", isOn: settings.pauseWhenOccluded)
            Toggle("Pause when displays sleep", isOn: settings.pauseWhenDisplaySleeps)
            Toggle("Pause while Lumen is hidden", isOn: settings.pauseWhenAppHidden)
            Toggle("Pause when I'm away", isOn: settings.pauseWhenIdle)
            if model.settings.pauseWhenIdle {
                Stepper(value: settings.idleMinutes, in: 1...240) {
                    Text("After \(model.settings.idleMinutes) minute\(model.settings.idleMinutes == 1 ? "" : "s") of inactivity")
                }
            }
        } header: {
            Text("Energy")
        } footer: {
            Text("Playback always pauses during sleep, screen lock, the screen saver, and when another user is logged in. When paused, no frames are decoded or drawn.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Wallpapers", value: "\(model.wallpapers.count)")
            LabeledContent("Thumbnail cache", value: Format.bytes(thumbnailUsage))
            HStack {
                Button("Regenerate Thumbnails") {
                    model.regenerateAllThumbnails()
                    refreshUsage()
                }
                Button("Remove Missing Items") { model.removeMissingWallpapers() }
                    .disabled(!model.wallpapers.contains { !$0.isAvailable })
                Button("Show Library Folder") { model.revealLibraryFolder() }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset Preferences…", role: .destructive) { confirmReset = true }
        }
    }

    private func refreshUsage() {
        let service = model.thumbnails
        Task {
            thumbnailUsage = await Task.detached(priority: .utility) { service.diskUsage() }.value
        }
    }
}
