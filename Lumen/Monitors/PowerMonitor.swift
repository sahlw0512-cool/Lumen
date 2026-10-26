import Foundation
import IOKit.ps
import Observation

/// Battery / AC state via IOKit power-source notifications (event-driven),
/// plus Low Power Mode via `NSProcessInfoPowerStateDidChange`.
@MainActor
@Observable
final class PowerMonitor {
    private(set) var isOnBattery = false
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var lowPowerObserver: NSObjectProtocol?

    func start() {
        guard runLoopSource == nil else { return }
        update()
        // `self` lives for the whole app session (owned by the engine singleton),
        // so an unretained context pointer is safe; `stop()` removes the source.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }

    func update() {
        var battery = false
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            // kIOPSBatteryPowerValue == "Battery Power"
            battery = (type as String) == "Battery Power"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard battery != isOnBattery || lowPower != isLowPowerMode else { return }
        isOnBattery = battery
        isLowPowerMode = lowPower
        Log.info("Power: \(battery ? "battery" : "AC")\(lowPower ? ", Low Power Mode" : "")", category: "power")
        onChange?()
    }
}

/// C callback for IOPSNotificationCreateRunLoopSource. Delivered on the main run loop.
private func powerSourcesChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.update() }
}
