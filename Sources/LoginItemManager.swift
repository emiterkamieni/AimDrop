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
}
