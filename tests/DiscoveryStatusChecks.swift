import Cocoa

@main struct DiscoveryStatusChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.aimdrop.discovery-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(completionSound: false, language: .polish)
        let app = AppDelegate()
        app.prepareForChecks(defaults: defaults, preferences: preferences, reservePicker: false) { _ in true }
        defer { app.closeForChecks() }
        // Native discovery can report before the worker's initial ready event.
        app.eventForChecks(["event": "discovery_status", "status": "waiting"])
        app.eventForChecks(["event": "ready", "name": preferences.receiverName,
                            "avatar_digest": app.appliedAvatarForChecks!])
        precondition(app.statusForChecks == "Oczekiwanie na Wi-Fi…")
        let id = UUID().uuidString.lowercased()
        app.eventForChecks(["event": "pending", "initial": true,
                            "transfers": [["id": id, "count": 1, "files": ["fixture.txt"]]]])
        func actions() -> [NSButton] {
            app.pendingMenuForChecks.submenu!.items.first { $0.representedObject as? String == id }!
                .submenu!.items.compactMap(\.view).flatMap(\.subviews).compactMap { $0 as? NSButton }
        }
        precondition(actions().count == 2 && actions().allSatisfy(\.isEnabled), "Discovery must not disable the durable inbox")
        app.eventForChecks(["event": "discovery_status", "status": "retrying"])
        precondition(app.statusForChecks == "Przywracanie widoczności odbiornika…")
        precondition(actions().allSatisfy(\.isEnabled))
        app.eventForChecks(["event": "accepted"])
        precondition(app.statusForChecks.hasPrefix("Oczekiwanie na pliki…"))
        app.eventForChecks(["event": "discovery_status", "status": "advertising"])
        precondition(app.statusForChecks == "Oczekiwanie na pliki…", "Recovery must retain transfer status")
        app.eventForChecks(["event": "offer_closed"])
        precondition(app.statusForChecks == "Gotowy do odbioru")
        app.eventForChecks(["event": "discovery_status", "status": "unknown"])
        precondition(app.statusForChecks == "Gotowy do odbioru")
        precondition(app.pendingIDsForChecks == [id])
        print("PASS: discovery status ordering/recovery preserves transfer status and usable inbox actions")
    }
}
