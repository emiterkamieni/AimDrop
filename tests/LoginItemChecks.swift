import Cocoa
import ServiceManagement

@main struct LoginItemChecks {
    static func checkDefaultRegistration() throws {
        for (initial, existing, expected) in [
            (SMAppService.Status.notRegistered, false, 1),
            (.notFound, false, 1),
            (.enabled, false, 0),
            (.requiresApproval, false, 0),
            (.notRegistered, true, 0)
        ] {
            let suite = "pl.aimdrop.login-default-checks." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var status = initial
            var registrations = 0
            let manager = LoginItemManager(status: { status }, register: {
                registrations += 1; status = .enabled
            }, unregister: { status = .notRegistered }, openSettings: {})
            try manager.enableByDefaultIfNeeded(existingInstallation: existing, defaults: defaults)
            precondition(registrations == expected)
            if expected == 1 { precondition(status == .enabled) }
            try manager.setEnabled(false)
            try manager.enableByDefaultIfNeeded(existingInstallation: false, defaults: UserDefaults(suiteName: suite)!)
            precondition(status == .notRegistered && registrations == expected,
                         "A later launch must preserve an explicit opt-out")
        }
        let suite = "pl.aimdrop.login-default-error." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var shouldFail = true, registrations = 0
        var status = SMAppService.Status.notRegistered
        let manager = LoginItemManager(status: { status }, register: {
            registrations += 1
            if shouldFail { throw PreferenceError(message: "Registration failed") }
            status = .enabled
        }, unregister: {}, openSettings: {})
        do {
            try manager.enableByDefaultIfNeeded(existingInstallation: false, defaults: defaults)
            fatalError("Registration error must be reported")
        } catch is PreferenceError { }
        try manager.enableByDefaultIfNeeded(existingInstallation: false, defaults: defaults)
        precondition(registrations == 1 && status == .notRegistered)
        shouldFail = false
        try manager.setEnabled(true)
        precondition(registrations == 2 && status == .enabled, "Manual retry must still work")
        print("PASS: default-on first launch, persistent opt-out, legacy/approval preservation and registration failure/manual retry")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        try checkDefaultRegistration()
        let suite = "pl.airfolder.login-settings-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(completionSound: false, language: .polish)
        let app = AppDelegate()
        var commands: [[String: Any]] = []
        app.prepareForChecks(defaults: defaults, preferences: preferences, storageDirectory: root) {
            commands.append($0); return true
        }
        defer { app.closeForChecks() }

        var status = SMAppService.Status.notFound
        var registerResult = SMAppService.Status.enabled
        var registrations = 0, removals = 0, settingsOpened = 0
        var failRegistration = false, failRemoval = false
        let manager = LoginItemManager(status: { status }, register: {
            registrations += 1
            if failRegistration { throw PreferenceError(message: "Próbny błąd rejestracji") }
            status = registerResult
        }, unregister: {
            removals += 1
            if failRemoval { throw PreferenceError(message: "Próbny błąd wyłączenia") }
            status = .notRegistered
        }, openSettings: { settingsOpened += 1 })
        let controller = SettingsWindowController(loginItems: manager)
        controller.onSave = { app.preferencesForChecks($0) }
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.present(preferences: preferences, status: "")
        defer { controller.close() }
        let view = controller.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func button(_ title: String) -> NSButton {
            descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        let checkbox = button("Uruchamiaj przy logowaniu")
        let save = button("Zapisz")
        let sound = button("Dźwięk po zapisaniu plików")
        let field = descendants(view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "receiverName" }!
        func focus() { controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window)) }
        func reopen() { controller.close(); controller.present(preferences: preferences, status: "") }

        // The stack detaches the status label when there is no actionable message.
        status = .requiresApproval
        focus()
        let hint = descendants(view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "loginItemStatus" }!
        status = .notFound
        focus()

        precondition(checkbox.state == .off && registrations == 0)
        precondition(hint.isHidden && hint.stringValue.isEmpty, "First registration must not show a missing-app error")
        checkbox.performClick(nil)
        precondition(checkbox.state == .on && registrations == 0, "Toggle must only edit the draft")
        reopen()
        precondition(checkbox.state == .off && registrations == 0, "Closing discards an unsaved toggle")
        checkbox.performClick(nil)
        field.stringValue = ""
        save.performClick(nil)
        precondition(registrations == 0, "Invalid settings must not change login registration")
        field.stringValue = preferences.receiverName
        controller.onSave = { _ in false }
        save.performClick(nil)
        precondition(registrations == 0 && save.isEnabled, "A failed preferences save must not apply autostart")
        controller.onSave = { app.preferencesForChecks($0) }
        save.performClick(nil)
        precondition(registrations == 1 && checkbox.state == .on && !save.isEnabled)
        precondition(commands.isEmpty, "Login-only Save must not reset the receiver profile or pairing")
        precondition(PreferencesStore(defaults: defaults).load() == preferences)

        // Changes outside AimDrop must be reflected even with other unsaved fields.
        sound.performClick(nil)
        status = .notRegistered
        focus()
        precondition(checkbox.state == .off)
        save.performClick(nil)
        precondition(registrations == 1 && removals == 0, "Unrelated Save must not restore an externally disabled login item")
        precondition(PreferencesStore(defaults: defaults).load().completionSound)

        status = .requiresApproval
        focus()
        precondition(checkbox.state == .off && hint.stringValue.contains("wyłączony w macOS"))
        let systemSettings = button("Ustawienia macOS…")
        precondition(!systemSettings.isHidden)
        checkbox.performClick(nil)
        save.performClick(nil)
        precondition(registrations == 1 && checkbox.state == .off, "Approval-required must not be displayed as enabled or re-registered")
        systemSettings.performClick(nil)
        precondition(settingsOpened == 1)
        status = .enabled
        focus()
        precondition(checkbox.state == .on && systemSettings.isHidden)
        checkbox.performClick(nil)
        focus()
        precondition(checkbox.state == .off, "Focus must preserve an intentionally edited login draft")
        save.performClick(nil)
        precondition(removals == 1 && status == .notRegistered)

        checkbox.performClick(nil)
        failRegistration = true
        save.performClick(nil)
        precondition(checkbox.state == .on && save.isEnabled && hint.stringValue.contains("Próbny błąd rejestracji"))
        controller.setSavedStatus("Odbiornik zaktualizowany.")
        precondition(hint.stringValue.contains("Próbny błąd rejestracji"), "Receiver feedback must not hide the autostart error")
        failRegistration = false
        save.performClick(nil)
        precondition(registrations == 3 && status == .enabled && !save.isEnabled)
        checkbox.performClick(nil)
        failRemoval = true
        save.performClick(nil)
        precondition(status == .enabled && checkbox.state == .off && save.isEnabled)
        precondition(hint.stringValue.contains("Próbny błąd wyłączenia"))
        failRemoval = false
        save.performClick(nil)
        precondition(removals == 3 && status == .notRegistered)

        registerResult = .requiresApproval
        checkbox.performClick(nil)
        save.performClick(nil)
        precondition(status == .requiresApproval && checkbox.state == .off && !systemSettings.isHidden)
        sound.performClick(nil)
        save.performClick(nil)
        precondition(removals == 3, "Saving an unrelated field must not unregister a pending approval")
        view.layoutSubtreeIfNeeded()
        let hintFrame = hint.convert(hint.bounds, to: view)
        let saveFrame = save.convert(save.bounds, to: view)
        precondition(hintFrame.minY >= saveFrame.maxY + 16, "Autostart text must stay clear of the footer buttons")
        status = .enabled
        focus()
        view.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count == 2, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: login draft/cancel, validated Save, real preferences wiring without profile reset, external status refresh, approval handling, enable/disable errors and retry, footer spacing")
    }
}
