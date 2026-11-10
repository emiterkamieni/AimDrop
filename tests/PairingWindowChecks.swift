import Cocoa

@main struct PairingWindowChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.aimdrop.pairing-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        app.prepareForChecks(defaults: defaults, preferences: AppPreferences(completionSound: false), reservePicker: false) { _ in true }
        defer { app.closeForChecks() }

        func panels() -> [NSWindow] { NSApp.windows.filter { $0 is NSPanel && $0.isVisible } }
        func show(_ code: String, until deadline: Date) {
            app.eventForChecks(["event": "pairing_pin", "code": code, "expires_at": deadline.timeIntervalSince1970])
        }
        func run(until deadline: Date, mode: RunLoop.Mode = .default) {
            while Date() < deadline { _ = RunLoop.current.run(mode: mode, before: deadline) }
        }

        app.eventForChecks(["event": "pairing_pin", "code": "123456"])
        show("123456", until: Date().addingTimeInterval(-1))
        precondition(panels().isEmpty, "Missing or expired deadlines must not open a PIN window")

        let deadline = Date().addingTimeInterval(1.5)
        show("123456", until: deadline)
        precondition(panels().count == 1)
        run(until: deadline.addingTimeInterval(-0.6))
        show("123456", until: deadline)
        precondition(panels().count == 1)
        run(until: deadline.addingTimeInterval(0.15), mode: .eventTracking)
        precondition(panels().isEmpty, "A retry must close at the original deadline, even while a menu is tracking")
        show("123456", until: deadline)
        precondition(panels().isEmpty, "Delayed IPC must not resurrect an expired PIN")

        let nextDeadline = Date().addingTimeInterval(2)
        show("654321", until: nextDeadline)
        let current = panels().first!
        show("123456", until: deadline)
        precondition(panels().count == 1 && panels().first === current, "A stale event must not replace a fresh PIN")
        app.eventForChecks(["event": "pairing_closed"])
        precondition(panels().isEmpty, "Successful pairing must still close the window")

        // A suspended UI can wake after its timer was due; close immediately.
        let wakeDeadline = Date().addingTimeInterval(0.4)
        show("234567", until: wakeDeadline)
        precondition(panels().count == 1)
        Thread.sleep(until: wakeDeadline.addingTimeInterval(0.1))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(panels().isEmpty, "An expired PIN must disappear on wake without another dialog")
        print("PASS: PIN retries retain the credential deadline; expiry, queued IPC, menu tracking, pairing success and wake close silently")
    }
}
