import Observation
import ServiceManagement

/// Uses `SMAppService.mainApp` (macOS 13+), the supported replacement for the
/// deprecated `SMLoginItemSetEnabled` / LaunchServices shared-file-list APIs.
@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
