import SwiftUI

/// Playlists that rotate wallpapers, and the daily schedule.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                playlistsSection
                ScheduleSection()
            }
            .padding(Theme.contentPadding)
        }
        .navigationTitle("Playlists")
        .navigationSubtitle(model.activePlaylist.map { "Playing “\($0.name)”" } ?? "Rotate wallpapers on a timer or a schedule")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let playlist = model.createPlaylist(named: "Playlist \(model.playlists.count + 1)")
                    selectedID = playlist.id
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists").font(.title3.weight(.semibold))
            if model.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A playlist rotates through wallpapers every few minutes, on wake, or at launch, with crossfades between them.")
                        .foregroundStyle(.secondary)
                    Button("Create Playlist") {
                        let all = model.availableWallpapers.map(\.id)
                        selectedID = model.createPlaylist(named: "All Wallpapers", with: all).id
                    }
                    .disabled(model.availableWallpapers.isEmpty)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            }
            ForEach(model.playlists) { playlist in
                PlaylistCard(playlist: playlist, isExpanded: selectedID == playlist.id) {
                    withAnimation(.snappy) { selectedID = selectedID == playlist.id ? nil : playlist.id }
                }
            }
        }
    }
}

private struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let isExpanded: Bool
    let toggle: () -> Void

    private var isActive: Bool { model.activePlaylistID == playlist.id }

    private func binding<T>(_ keyPath: WritableKeyPath<Playlist, T>) -> Binding<T> {
        Binding(get: { playlist[keyPath: keyPath] }, set: { value in
            var updated = playlist
            updated[keyPath: keyPath] = value
            model.updatePlaylist(updated)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                thumbnails
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Text("\(playlist.wallpaperIDs.count) wallpaper\(playlist.wallpaperIDs.count == 1 ? "" : "s") · \(Playlist.intervalTitle(playlist.intervalMinutes))\(playlist.shuffle ? " · Shuffle" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Button("Next", systemImage: "forward.fill") { model.advancePlaylist() }
                    Button("Stop", systemImage: "stop.fill") { model.stopPlaylist() }
                } else {
                    Button("Play", systemImage: "play.fill") { model.startPlaylist(playlist.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(playlist.wallpaperIDs.isEmpty)
                }
                Button(action: toggle) {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide details" : "Edit playlist")
            }

            if isExpanded {
                Divider()
                HStack(spacing: 18) {
                    Picker("Change", selection: binding(\.intervalMinutes)) {
                        ForEach(Playlist.intervalChoices, id: \.self) { minutes in
                            Text(Playlist.intervalTitle(minutes)).tag(minutes)
                        }
                    }
                    .frame(maxWidth: 260)
                    Toggle("Shuffle", isOn: binding(\.shuffle))
                    Toggle("On wake", isOn: binding(\.advanceOnWake))
                    Toggle("On launch", isOn: binding(\.advanceOnLaunch))
                }
                .toggleStyle(.checkbox)

                PlaylistContents(playlist: playlist)

                HStack {
                    Spacer()
                    Button("Delete Playlist", role: .destructive) { model.deletePlaylist(playlist.id) }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isActive ? 1.5 : 1)
        }
    }

    private var thumbnails: some View {
        HStack(spacing: -18) {
            ForEach(playlist.wallpaperIDs.prefix(3), id: \.self) { id in
                if let wallpaper = model.wallpaper(id: id) {
                    ThumbnailImage(wallpaper: wallpaper)
                        .frame(width: 54, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.4)))
                }
            }
            if playlist.wallpaperIDs.isEmpty {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.placeholderGradient)
                    .frame(width: 54, height: 34)
            }
        }
        .frame(width: 92, alignment: .leading)
    }
}

/// Ordered list with add/remove/reorder.
private struct PlaylistContents: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(playlist.wallpaperIDs.enumerated()), id: \.element) { index, id in
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                    if let wallpaper = model.wallpaper(id: id) {
                        ThumbnailImage(wallpaper: wallpaper)
                            .frame(width: 48, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(wallpaper.title).lineLimit(1)
                        if !wallpaper.isAvailable { Chip(text: "Missing") }
                    }
                    Spacer()
                    Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == playlist.wallpaperIDs.count - 1)
                    Button { remove(id) } label: { Image(systemName: "minus.circle") }
                        .help("Remove from playlist")
                }
                .buttonStyle(.borderless)
            }
            Menu {
                let missing = model.availableWallpapers.filter { !playlist.wallpaperIDs.contains($0.id) }
                if missing.isEmpty { Text("Every wallpaper is in this playlist") }
                Button("Add All") {
                    var updated = playlist
                    updated.wallpaperIDs += missing.map(\.id)
                    model.updatePlaylist(updated)
                }
                .disabled(missing.isEmpty)
                Divider()
                ForEach(missing) { wallpaper in
                    Button(wallpaper.title) { model.addToPlaylist(wallpaper.id, playlistID: playlist.id) }
                }
            } label: {
                Label("Add Wallpaper", systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        var updated = playlist
        guard let from = updated.wallpaperIDs.firstIndex(of: id), updated.wallpaperIDs.indices.contains(from + offset) else { return }
        updated.wallpaperIDs.swapAt(from, from + offset)
        model.updatePlaylist(updated)
    }

    private func remove(_ id: UUID) {
        var updated = playlist
        updated.wallpaperIDs.removeAll { $0 == id }
        model.updatePlaylist(updated)
    }
}

/// Daily schedule: switch wallpapers or playlists at set times, sunrise, or sunset.
private struct ScheduleSection: View {
    @Environment(AppModel.self) private var model

    private var schedule: WallpaperSchedule { model.schedule }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedule").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { enabled in
                        var updated = schedule
                        updated.isEnabled = enabled
                        model.setSchedule(updated)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text("Change wallpapers through the day, such as a bright scene at sunrise and a calm one after sunset. The schedule takes over from manual choices at each change.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(schedule.entries) { entry in
                    ScheduleRow(entry: entry)
                }
                HStack {
                    Menu {
                        Button("At a Time") { add(.time(minutes: 9 * 60)) }
                        Button("At Sunrise") { add(.sunrise(offset: 0)) }
                        Button("At Sunset") { add(.sunset(offset: 0)) }
                    } label: {
                        Label("Add Change", systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(model.availableWallpapers.isEmpty)
                    Spacer()
                    if schedule.isEnabled, let next = model.rotation.nextScheduleChange {
                        Text("Next change \(next.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))

            if schedule.entries.contains(where: { $0.trigger.isSolar }) {
                locationRow
            }
        }
    }

    @ViewBuilder
    private var locationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "location")
            if let location = model.settings.location, let times = SolarCalculator.times(on: Date(), at: location) {
                Text("Today: sunrise \(times.sunrise.formatted(date: .omitted, time: .shortened)), sunset \(times.sunset.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Sunrise and sunset need your approximate location. Only a rounded position is kept, on this Mac.")
            }
            Spacer()
            Button(model.settings.location == nil ? "Use My Location" : "Update Location") {
                model.rotation.location.request()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func add(_ trigger: ScheduleTrigger) {
        guard let first = model.availableWallpapers.first else { return }
        var updated = schedule
        updated.entries.append(ScheduleEntry(trigger: trigger, target: .wallpaper(first.id)))
        if updated.entries.count == 1 { updated.isEnabled = true }
        model.setSchedule(updated)
    }
}

private struct ScheduleRow: View {
    @Environment(AppModel.self) private var model
    let entry: ScheduleEntry

    private func update(_ change: (inout ScheduleEntry) -> Void) {
        var schedule = model.schedule
        guard let index = schedule.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        change(&schedule.entries[index])
        model.setSchedule(schedule)
    }

    var body: some View {
        HStack(spacing: 12) {
            triggerEditor
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("Show", selection: Binding(get: { entry.target }, set: { target in update { $0.target = target } })) {
                Section("Wallpapers") {
                    ForEach(model.availableWallpapers) { wallpaper in
                        Text(wallpaper.title).tag(ScheduleTarget.wallpaper(wallpaper.id))
                    }
                }
                if !model.playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(model.playlists) { playlist in
                            Text("Playlist: \(playlist.name)").tag(ScheduleTarget.playlist(playlist.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            Spacer()
            Button {
                var schedule = model.schedule
                schedule.entries.removeAll { $0.id == entry.id }
                model.setSchedule(schedule)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    @ViewBuilder
    private var triggerEditor: some View {
        switch entry.trigger {
        case .time(let minutes):
            DatePicker("Time", selection: Binding(
                get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    update { $0.trigger = .time(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0)) }
                }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .frame(width: 110)
        case .sunrise(let offset), .sunset(let offset):
            let isSunrise = { if case .sunrise = entry.trigger { return true } else { return false } }()
            HStack(spacing: 6) {
                Image(systemName: isSunrise ? "sunrise.fill" : "sunset.fill")
                    .foregroundStyle(.orange)
                Picker("Offset", selection: Binding(get: { offset }, set: { newOffset in
                    update { $0.trigger = isSunrise ? .sunrise(offset: newOffset) : .sunset(offset: newOffset) }
                })) {
                    ForEach([-60, -30, -15, 0, 15, 30, 60], id: \.self) { value in
                        Text(ScheduleTrigger.sunrise(offset: value).title.replacingOccurrences(of: "sunrise", with: isSunrise ? "sunrise" : "sunset")
                            .replacingOccurrences(of: "Sunrise", with: isSunrise ? "Sunrise" : "Sunset")).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
        }
    }
}
