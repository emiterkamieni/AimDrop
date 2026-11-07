import Foundation
import ServiceManagement

struct LoginItemManager {
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void
    let openSettings: () -> Void

    static var system: LoginItemManager {
        LoginItemManager(status: { SMAppService.mainApp.status },
                         register: { try SMAppService.mainApp.register() },
                         unregister: { try SMAppService.mainApp.unregister() },
                         openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    func setEnabled(_ enabled: Bool) throws {
        let current = status()
        if enabled {
            // An existing registration blocked by the user needs approval in
            // System Settings, not another registration from the application.
            if current != .enabled && current != .requiresApproval { try register() }
        } else if current == .enabled || current == .requiresApproval {
            try unregister()
        }
    }

    func enableByDefaultIfNeeded(existingInstallation: Bool, defaults: UserDefaults = .standard) throws {
        let key = "AimDropLoginDefaultApplied.v1"
        guard !defaults.bool(forKey: key) else { return }
        // Apply the default once. Later choices in AimDrop or macOS must win,
        // including old installations whose login setting was managed by the OS.
        defaults.set(true, forKey: key)
        guard !existingInstallation else { return }
        try setEnabled(true)
    }
}
