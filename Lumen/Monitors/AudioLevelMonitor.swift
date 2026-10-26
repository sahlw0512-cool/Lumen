import AVFoundation
import Observation

/// Measures the level of the default audio input for audio-reactive effects.
///
/// Uses the microphone (or any input device the user selects in System
/// Settings, such as a loopback device), so it only runs after the user turns
/// the effect on and grants permission. Audio is reduced to a single level
/// number in memory and never stored or sent anywhere.
@MainActor
@Observable
final class AudioLevelMonitor {
    enum Permission {
        case notDetermined, granted, denied
    }

    private(set) var permission: Permission = AudioLevelMonitor.currentPermission()
    private(set) var isRunning = false
    /// Smoothed level in 0...1, published about 30 times a second while running.
    private(set) var level: Double = 0

    @ObservationIgnored var onLevel: ((Double) -> Void)?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var wantsRunning = false

    static func currentPermission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Shows the system permission prompt. Call only from an explicit user action.
    func requestPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permission = granted ? .granted : .denied
        if granted && wantsRunning { start() }
        return granted
    }

    func start() {
        wantsRunning = true
        permission = Self.currentPermission()
        guard !isRunning, permission == .granted else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.warning("No audio input available for audio-reactive effects", category: "audio")
            return
        }
        let bufferSize = AVAudioFrameCount(max(format.sampleRate / 30, 256))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format,
                         block: Self.makeTap { [weak self] value in self?.ingest(value) })
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
            Log.info("Audio-reactive effects listening", category: "audio")
        } catch {
            input.removeTap(onBus: 0)
            Log.warning("Couldn't start audio input: \(error.localizedDescription)", category: "audio")
        }
    }

    func stop() {
        wantsRunning = false
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false
        level = 0
        Log.info("Audio-reactive effects stopped listening", category: "audio")
    }

    /// Built outside the main actor: the tap runs on the audio thread and
    /// reduces each buffer to one RMS level before hopping to the main actor.
    private nonisolated static func makeTap(_ deliver: @escaping @MainActor (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(count))
            // -50 dB...-5 dB mapped to 0...1.
            let db = 20 * log10(max(rms, 0.000_01))
            let normalized = Double(min(max((db + 50) / 45, 0), 1))
            Task { @MainActor in deliver(normalized) }
        }
    }

    private func ingest(_ value: Double) {
        guard isRunning else { return }
        // Fast attack, slow release reads as a "pulse" rather than jitter.
        let factor = value > level ? 0.6 : 0.15
        level += (value - level) * factor
        onLevel?(level)
    }
}
