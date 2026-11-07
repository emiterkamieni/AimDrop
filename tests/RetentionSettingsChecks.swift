import Cocoa

@main struct RetentionSettingsChecks {
    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        L10n.configure(.polish)
        let original = AppPreferences(receiverName: "My receiver", completionSound: false, language: .polish)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "retentionDays"); legacy.removeValue(forKey: "automaticTrash")
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored == original && restored.retentionDays == 7 && restored.automaticTrash)
        legacy["retentionDays"] = -1
        let repaired = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(repaired.receiverName == original.receiverName && repaired.retentionDays == 7)

        let settings = SettingsWindowController()
        var saved: [AppPreferences] = []
        settings.onSave = { saved.append($0); return true }
        settings.present(preferences: original, status: "")
        let views = descendants(settings.window!.contentView!)
        let days = views.first { $0.identifier?.rawValue == "retentionDays" } as! NSTextField
        let automatic = views.first { $0.identifier?.rawValue == "automaticTrash" } as! NSButton
        let save = views.compactMap { $0 as? NSButton }.first { $0.title == "Zapisz" }!
        precondition(days.stringValue == "7" && automatic.state == .on)
        for invalid in ["0", "-1", "3.5", "36501", "abc"] {
            days.stringValue = invalid
            settings.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: days))
            save.performClick(nil)
            precondition(saved.isEmpty, "Invalid retention must not be saved")
        }
        days.stringValue = "12"
        automatic.performClick(nil)
        save.performClick(nil)
        precondition(saved.count == 1 && saved[0].retentionDays == 12 && !saved[0].automaticTrash)
        days.stringValue = "30"
        settings.close()
        settings.present(preferences: saved[0], status: "")
        precondition(days.stringValue == "12" && automatic.state == .off, "Closing must discard draft changes")
        settings.close()

        let suite = "pl.aimdrop.retention-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppDelegate()
        var commands: [[String: Any]] = []
        app.prepareForChecks(defaults: defaults, preferences: original, storageDirectory: root) { commands.append($0); return true }
        precondition(app.preferencesForChecks(saved[0]))
        precondition(commands.count == 1 && commands[0]["command"] as? String == "set_retention")
        precondition(commands[0]["days"] as? Int == 12 && commands[0]["enabled"] as? Bool == false)
        app.eventForChecks(["event": "retention_result", "request_id": commands[0]["request_id"]!, "ok": true])
        precondition(PreferencesStore(defaults: defaults).load().retentionDays == 12)
        precondition(app.preferencesForChecks(saved[0]) && commands.count == 1)
        app.closeForChecks()
        print("PASS: retention migration defaults, invalid-field isolation, UI validation, draft cancellation, persistence and live policy command without profile changes")
    }
}
