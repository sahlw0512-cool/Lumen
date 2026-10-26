import AppKit
import CoreLocation

/// Drives playlist rotation and the daily schedule with a single timer set
/// for the next moment something should change. Nothing polls.
@MainActor
final class RotationController {
    private unowned let model: AppModel
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastAdvance = Date()
    private var appliedEntryID: UUID?
    let location = LocationProvider()

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        location.onUpdate = { [weak self] coordinates in
            self?.model.settings.location = coordinates
        }
        applySchedule(force: true)
        if model.activePlaylist?.advanceOnLaunch == true {
            model.advancePlaylist()
        }
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func playlistAdvanced() {
        lastAdvance = Date()
        reschedule()
    }

    /// Sunrise and sunset for `date` at the saved location, if known.
    func solarTimes(on date: Date) -> SolarTimes? {
        model.settings.location.flatMap { SolarCalculator.times(on: date, at: $0) }
    }

    var nextPlaylistChange: Date? {
        guard let playlist = model.activePlaylist, playlist.intervalMinutes > 0 else { return nil }
        return lastAdvance.addingTimeInterval(TimeInterval(playlist.intervalMinutes * 60))
    }

    var nextScheduleChange: Date? {
        guard model.schedule.isEnabled else { return nil }
        return model.schedule.nextChange(after: Date(), solar: solarTimes(on:))
    }

    /// Re-arms the timer for whichever comes first: the next playlist step or
    /// the next schedule boundary.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        if model.schedule.isEnabled, model.schedule.entries.contains(where: { $0.trigger.isSolar }),
           model.settings.location == nil {
            location.requestIfAuthorized()
        }
        guard let fireDate = [nextPlaylistChange, nextScheduleChange].compactMap({ $0 }).min() else { return }
        let timer = Timer(fire: max(fireDate, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Switches to the schedule's current entry if it changed (or when forced,
    /// e.g. after the schedule is edited or the Mac wakes).
    func applySchedule(force: Bool = false) {
        guard model.schedule.isEnabled,
              let entry = model.schedule.activeEntry(at: Date(), solar: solarTimes(on:)) else { return }
        guard force || entry.id != appliedEntryID else { return }
        appliedEntryID = entry.id
        model.activate(entry.target)
    }

    private func fire() {
        let now = Date()
        applySchedule()
        if let next = nextPlaylistChange, next <= now.addingTimeInterval(1) {
            model.advancePlaylist()   // calls playlistAdvanced(), which reschedules
        }
        reschedule()
    }

    private func didWake() {
        applySchedule(force: true)
        if model.activePlaylist?.advanceOnWake == true {
            model.advancePlaylist()
        }
        reschedule()
    }
}

/// One-shot location for sunrise/sunset. Asked for only when the user adds a
/// sunrise or sunset trigger; only a rounded position is kept.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    var onUpdate: ((Coordinates) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Shows the permission prompt if needed. Call from a user action.
    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    /// Refreshes silently when permission was already granted.
    func requestIfAuthorized() {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorized { manager.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorized { manager.requestLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // About 1 km of precision is plenty for sunrise/sunset.
        let coordinates = Coordinates(latitude: (location.coordinate.latitude * 100).rounded() / 100,
                                      longitude: (location.coordinate.longitude * 100).rounded() / 100)
        Task { @MainActor in self.onUpdate?(coordinates) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in Log.warning("Location unavailable: \(error.localizedDescription)", category: "schedule") }
    }
}
