import Foundation

// MARK: - Playlists

/// An ordered set of wallpapers that rotate on a timer and/or on events.
struct Playlist: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var wallpaperIDs: [UUID] = []
    /// Minutes between changes; 0 = only on the events below.
    var intervalMinutes: Int = 30
    var shuffle = false
    var advanceOnWake = false
    var advanceOnLaunch = false

    init(name: String, wallpaperIDs: [UUID] = []) {
        self.name = name
        self.wallpaperIDs = wallpaperIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, wallpaperIDs, intervalMinutes, shuffle, advanceOnWake, advanceOnLaunch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        name = c.value(.name, or: "Playlist")
        wallpaperIDs = c.value(.wallpaperIDs, or: [])
        intervalMinutes = min(max(c.value(.intervalMinutes, or: 30), 0), 24 * 60)
        shuffle = c.value(.shuffle, or: false)
        advanceOnWake = c.value(.advanceOnWake, or: false)
        advanceOnLaunch = c.value(.advanceOnLaunch, or: false)
    }

    static let intervalChoices = [0, 1, 5, 10, 15, 30, 60, 120, 240, 480, 1440]

    static func intervalTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Only on Events"
        case 1: "Every Minute"
        case ..<60: "Every \(minutes) Minutes"
        case 60: "Every Hour"
        case 1440: "Every Day"
        default: "Every \(minutes / 60) Hours"
        }
    }

    /// The wallpaper after `current`, skipping missing ones. Shuffle never
    /// repeats the current wallpaper when there is a choice.
    func next(after current: UUID?, available: Set<UUID>, random: () -> Double = { Double.random(in: 0..<1) }) -> UUID? {
        let candidates = wallpaperIDs.filter(available.contains)
        guard !candidates.isEmpty else { return nil }
        if shuffle {
            let pool = candidates.count > 1 ? candidates.filter { $0 != current } : candidates
            return pool[min(Int(random() * Double(pool.count)), pool.count - 1)]
        }
        guard let current, let index = candidates.firstIndex(of: current) else { return candidates[0] }
        return candidates[(index + 1) % candidates.count]
    }
}

// MARK: - Schedules

enum ScheduleTrigger: Codable, Equatable, Hashable, Sendable {
    /// Minutes after midnight.
    case time(minutes: Int)
    /// Minutes relative to sunrise/sunset (negative = before).
    case sunrise(offset: Int)
    case sunset(offset: Int)

    var title: String {
        switch self {
        case .time(let minutes):
            let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        case .sunrise(let offset): return Self.solarTitle("Sunrise", offset)
        case .sunset(let offset): return Self.solarTitle("Sunset", offset)
        }
    }

    var isSolar: Bool {
        if case .time = self { return false }
        return true
    }

    private static func solarTitle(_ name: String, _ offset: Int) -> String {
        if offset == 0 { return name }
        return "\(abs(offset)) min \(offset < 0 ? "before" : "after") \(name.lowercased())"
    }
}

/// What a schedule entry switches to.
enum ScheduleTarget: Codable, Equatable, Hashable, Sendable {
    case wallpaper(UUID)
    case playlist(UUID)
}

struct ScheduleEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var trigger: ScheduleTrigger
    var target: ScheduleTarget
}

/// Daily wallpaper schedule (e.g. one at sunrise, another at sunset).
struct WallpaperSchedule: Codable, Equatable, Sendable {
    var isEnabled = false
    var entries: [ScheduleEntry] = []

    /// The entry in effect at `date`: the latest trigger that has passed today,
    /// or yesterday's last one before today's first trigger.
    func activeEntry(at date: Date, calendar: Calendar = .current, solar: (Date) -> SolarTimes?) -> ScheduleEntry? {
        let resolved = entries.compactMap { entry -> (ScheduleEntry, Int)? in
            guard let minute = Self.minuteOfDay(for: entry.trigger, on: date, calendar: calendar, solar: solar) else { return nil }
            return (entry, minute)
        }
        guard !resolved.isEmpty else { return nil }
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let sorted = resolved.sorted { $0.1 < $1.1 }
        return (sorted.last { $0.1 <= now } ?? sorted.last)?.0
    }

    /// The next moment after `date` when the active entry may change.
    func nextChange(after date: Date, calendar: Calendar = .current, solar: (Date) -> SolarTimes?) -> Date? {
        var candidates: [Date] = []
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let start = calendar.startOfDay(for: day)
            for entry in entries {
                guard let minute = Self.minuteOfDay(for: entry.trigger, on: day, calendar: calendar, solar: solar),
                      let when = calendar.date(byAdding: .minute, value: minute, to: start), when > date else { continue }
                candidates.append(when)
            }
        }
        return candidates.min()
    }

    static func minuteOfDay(for trigger: ScheduleTrigger, on date: Date, calendar: Calendar, solar: (Date) -> SolarTimes?) -> Int? {
        func minute(of event: Date) -> Int {
            calendar.component(.hour, from: event) * 60 + calendar.component(.minute, from: event)
        }
        switch trigger {
        case .time(let minutes):
            return min(max(minutes, 0), 1439)
        case .sunrise(let offset):
            guard let times = solar(date) else { return nil }
            return min(max(minute(of: times.sunrise) + offset, 0), 1439)
        case .sunset(let offset):
            guard let times = solar(date) else { return nil }
            return min(max(minute(of: times.sunset) + offset, 0), 1439)
        }
    }
}

// MARK: - Sunrise / sunset

struct Coordinates: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

struct SolarTimes: Equatable, Sendable {
    var sunrise: Date
    var sunset: Date
}

/// NOAA's simplified solar position algorithm; accurate to about a minute
/// outside the polar regions, where it returns nil on days without a sunrise or sunset.
enum SolarCalculator {
    static func times(on date: Date, at coordinates: Coordinates, calendar: Calendar = .current) -> SolarTimes? {
        guard let sunrise = event(on: date, at: coordinates, rising: true, calendar: calendar),
              let sunset = event(on: date, at: coordinates, rising: false, calendar: calendar) else { return nil }
        return SolarTimes(sunrise: sunrise, sunset: sunset)
    }

    private static func event(on date: Date, at c: Coordinates, rising: Bool, calendar: Calendar) -> Date? {
        let rad = Double.pi / 180
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let lngHour = c.longitude / 15
        let t = dayOfYear + ((rising ? 6 : 18) - lngHour) / 24
        let meanAnomaly = 0.9856 * t - 3.289
        var trueLongitude = meanAnomaly + 1.916 * sin(meanAnomaly * rad) + 0.020 * sin(2 * meanAnomaly * rad) + 282.634
        trueLongitude = trueLongitude.truncatingRemainder(dividingBy: 360)
        if trueLongitude < 0 { trueLongitude += 360 }

        var rightAscension = atan(0.91764 * tan(trueLongitude * rad)) / rad
        rightAscension = rightAscension.truncatingRemainder(dividingBy: 360)
        if rightAscension < 0 { rightAscension += 360 }
        let lQuadrant = floor(trueLongitude / 90) * 90
        let raQuadrant = floor(rightAscension / 90) * 90
        rightAscension = (rightAscension + lQuadrant - raQuadrant) / 15

        let sinDec = 0.39782 * sin(trueLongitude * rad)
        let cosDec = cos(asin(sinDec))
        let zenith = 90.833
        let cosH = (cos(zenith * rad) - sinDec * sin(c.latitude * rad)) / (cosDec * cos(c.latitude * rad))
        guard cosH >= -1, cosH <= 1 else { return nil }
        let hourAngle = (rising ? 360 - acos(cosH) / rad : acos(cosH) / rad) / 15

        let localMean = hourAngle + rightAscension - 0.06571 * t - 6.622
        var utc = (localMean - lngHour).truncatingRemainder(dividingBy: 24)
        if utc < 0 { utc += 24 }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let midnightUTC = utcCalendar.date(from: parts) else { return nil }
        var result = midnightUTC.addingTimeInterval(utc * 3600)
        // Keep the event on the requested local day.
        let localDay = calendar.startOfDay(for: date)
        if result < localDay { result += 86_400 }
        if result >= localDay.addingTimeInterval(86_400) { result -= 86_400 }
        return result
    }
}

// MARK: - Effect presets

struct EffectPreset: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Only the picture adjustments are used; clock, parallax, and audio stay global.
    var effects: WallpaperEffects
    var isBuiltIn = false

    static func == (a: EffectPreset, b: EffectPreset) -> Bool { a.id == b.id && a.name == b.name && a.effects == b.effects }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let builtIn: [EffectPreset] = {
        func preset(_ uuid: String, _ name: String, _ configure: (inout WallpaperEffects) -> Void) -> EffectPreset {
            var effects = WallpaperEffects()
            configure(&effects)
            return EffectPreset(id: UUID(uuidString: uuid)!, name: name, effects: effects, isBuiltIn: true)
        }
        return [
            preset("6E4C1E7A-0000-4000-8000-000000000001", "Original") { _ in },
            preset("6E4C1E7A-0000-4000-8000-000000000002", "Calm") {
                $0.saturation = 0.7; $0.brightness = -0.05; $0.contrast = 0.92; $0.vignette = 0.35
            },
            preset("6E4C1E7A-0000-4000-8000-000000000003", "Focus") {
                $0.blur = 18; $0.brightness = -0.12; $0.saturation = 0.6; $0.vignette = 0.25
            },
            preset("6E4C1E7A-0000-4000-8000-000000000004", "Vivid") {
                $0.saturation = 1.35; $0.contrast = 1.12; $0.brightness = 0.02
            },
            preset("6E4C1E7A-0000-4000-8000-000000000005", "Night") {
                $0.brightness = -0.18; $0.saturation = 0.8; $0.tintAmount = 0.25; $0.tint = .amber; $0.vignette = 0.5
            },
            preset("6E4C1E7A-0000-4000-8000-000000000006", "Monochrome") {
                $0.saturation = 0; $0.contrast = 1.1
            },
        ]
    }()
}

extension WallpaperEffects {
    /// Copies this value's picture adjustments onto `base`, keeping base's
    /// global settings (clock, parallax, audio, dark mode).
    func adjustments(appliedTo base: WallpaperEffects) -> WallpaperEffects {
        var result = base
        result.blur = blur
        result.brightness = brightness
        result.contrast = contrast
        result.saturation = saturation
        result.tint = tint
        result.tintAmount = tintAmount
        result.vignette = vignette
        return result
    }
}
