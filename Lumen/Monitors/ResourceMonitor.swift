import Darwin
import Foundation
import Observation

/// Samples Lumen's own CPU, memory, and energy use. Runs only while the
/// Performance view is open; nothing is sampled in the background.
///
/// Video decoding happens in macOS's media services, so these numbers cover
/// Lumen's process only. Hardware-decoded video adds little on top.
@MainActor
@Observable
final class ResourceMonitor {
    struct Sample: Equatable {
        var date: Date
        /// Percent of one core (100 = one core fully busy).
        var cpuPercent: Double
        var memoryBytes: UInt64
        /// Average power over the sample interval, when the system reports it.
        var watts: Double?
    }

    enum Impact: String {
        case low = "Low", moderate = "Moderate", high = "High"
    }

    private(set) var latest: Sample?
    private(set) var history: [Sample] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previous: (time: UInt64, cpu: UInt64, energy: UInt64)?
    @ObservationIgnored private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        previous = nil
    }

    /// A rough Activity Monitor-style rating from CPU use.
    var impact: Impact? {
        guard let latest else { return nil }
        if latest.cpuPercent < 3 { return .low }
        if latest.cpuPercent < 15 { return .moderate }
        return .high
    }

    private func sample() {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return }

        let now = mach_absolute_time()
        let cpu = info.ri_user_time + info.ri_system_time
        let energy = info.ri_energy_nj
        defer { previous = (now, cpu, energy) }
        guard let previous, now > previous.time else { return }

        let elapsedNs = Double(now - previous.time) * timebase
        // CPU times are reported in Mach absolute time units.
        let cpuNs = Double(cpu &- previous.cpu) * timebase
        let watts: Double? = energy > 0 && energy >= previous.energy
            ? Double(energy - previous.energy) / elapsedNs   // nJ / ns = W
            : nil

        let sample = Sample(date: Date(), cpuPercent: max(cpuNs / elapsedNs * 100, 0),
                            memoryBytes: info.ri_phys_footprint, watts: watts)
        latest = sample
        history.append(sample)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}
