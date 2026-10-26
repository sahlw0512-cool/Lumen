import AppKit
import SwiftUI

/// Live engine, system, and log state for troubleshooting.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    private let log = DiagnosticsLog.shared

    var body: some View {
        Form {
            Section("Displays") {
                ForEach(model.displayManager.displays) { display in
                    let state = model.engine.displayStates[display.id]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            StatusDot(status: state?.status ?? .empty, pauseReason: state?.pauseReason)
                            Text(display.name).font(.headline)
                            Text("ID \(display.displayID)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text("\(display.pixelsLabel) · \(display.pointsLabel) · frame \(Int(display.frame.minX)),\(Int(display.frame.minY))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("State: \(StatusDot.label(status: state?.status ?? .empty, pauseReason: state?.pauseReason))")
                            .font(.caption)
                        Text("Wallpaper: \(model.wallpaper(id: state?.wallpaperID)?.title ?? "—")")
                            .font(.caption)
                        Text("Key: \(display.id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("System") {
                row("Power source", model.engine.power.isOnBattery ? "Battery" : "AC")
                row("Low Power Mode", model.engine.power.isLowPowerMode)
                row("Thermal state", SystemStateMonitor.describe(model.engine.system.thermalState))
                row("System asleep", model.engine.system.isSystemAsleep)
                row("Displays asleep", model.engine.system.areScreensAsleep)
                row("Screen locked", model.engine.system.isScreenLocked)
                row("Screen saver", model.engine.system.isScreenSaverRunning)
                row("Session active", model.engine.system.isSessionActive)
                row("User idle", model.engine.idle.isIdle)
                row("Fullscreen displays", "\(model.engine.fullscreenDisplayIDs.count)")
                row("User paused", model.engine.isUserPaused)
            }

            Section {
                if log.entries.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(log.entries.suffix(200).reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.level.symbol)
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 14)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.category)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(entry.message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Event Log")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.exportText, forType: .string)
                    }
                    Button("Clear") { log.clear() }
                }
            }

            Section("Actions") {
                HStack {
                    Button("Reload Wallpapers") { model.reloadAllWallpapers() }
                    Button("Show Library Folder") { model.revealLibraryFolder() }
                }
                Text("Detailed logs are also available in Console.app (subsystem: \(Bundle.main.bundleIdentifier ?? "Lumen")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    private func row(_ title: String, _ value: Bool) -> some View {
        row(title, value ? "Yes" : "No")
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospaced().foregroundStyle(.secondary)
        }
    }

    private func color(for level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
