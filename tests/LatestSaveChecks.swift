import Cocoa

@main struct LatestSaveChecks {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Folder picker did not settle")
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.airfolder.latest-save-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var commands: [[String: Any]] = []
        let preferences = AppPreferences(completionSound: false, language: .polish)
        func makeApp() -> AppDelegate {
            let app = AppDelegate()
            app.prepareForChecks(defaults: defaults, preferences: preferences, storageDirectory: root, reservePicker: false) {
                commands.append($0); return true
            }
            return app
        }
        func receipt(_ id: String) -> [String: Any] {
            ["id": id, "count": 1, "files": ["received.txt"], "paths": [root.appendingPathComponent("received.txt").path]]
        }
        let old = UUID().uuidString, newest = UUID().uuidString
        let app = makeApp()
        let item = app.latestSaveItemForChecks
        precondition(item.isHidden)
        app.eventForChecks(["event": "pending", "transfers": [receipt(old)], "latest_received_id": old])
        precondition(!item.isHidden && item.isEnabled && app.latestSaveIDForChecks == old)
        precondition(NSApp.sendAction(item.action!, to: app, from: item))
        wait { app.currentFolderIDForChecks == old }
        precondition(item.isHidden, "Do not offer a second chooser for the same batch")
        app.cancelFolderForChecks()
        wait { app.currentFolderIDForChecks == nil }
        precondition(!item.isHidden && item.isEnabled && app.pendingIDsForChecks.contains(old))
        precondition(commands.last?["command"] as? String == "defer" && commands.last?["id"] as? String == old)

        app.eventForChecks(receipt(newest).merging(["event": "downloaded", "latest_received_id": newest]) { _, new in new })
        wait { app.currentFolderIDForChecks == newest }
        app.cancelFolderForChecks()
        wait { app.currentFolderIDForChecks == nil }
        precondition(app.latestSaveIDForChecks == newest && !item.isHidden)
        // A late snapshot or an older notification must not redirect this action.
        app.eventForChecks(["event": "pending", "transfers": [receipt(old)], "latest_received_id": newest])
        precondition(NSApp.sendAction(item.action!, to: app, from: item))
        wait { app.currentFolderIDForChecks == newest }
        app.cancelFolderForChecks()
        wait { app.currentFolderIDForChecks == nil }
        app.eventForChecks(["event": "saving", "id": newest])
        precondition(item.isHidden)
        app.eventForChecks(["event": "save_canceled", "id": newest])
        precondition(!item.isHidden && app.latestSaveIDForChecks == newest)
        app.eventForChecks(["event": "complete", "id": newest, "count": 1])
        app.eventForChecks(["event": "pending", "transfers": [receipt(old)], "latest_received_id": newest])
        precondition(item.isHidden && app.latestSaveIDForChecks == nil, "Saving latest must not resurrect the previous unsaved transfer")
        app.closeForChecks()

        let restored = makeApp()
        restored.eventForChecks(["event": "pending", "transfers": [receipt(old)], "latest_received_id": newest])
        precondition(restored.latestSaveItemForChecks.isHidden, "The saved latest ID must still suppress older batches after restart")
        restored.closeForChecks()
        let unsaved = makeApp()
        unsaved.eventForChecks(["event": "pending", "transfers": [receipt(old), receipt(newest)], "latest_received_id": newest])
        precondition(unsaved.latestSaveIDForChecks == newest && !unsaved.latestSaveItemForChecks.isHidden)
        unsaved.closeForChecks()
        print("PASS: latest-only save menu, real chooser reopen/cancel, in-progress hiding, retry after save cancellation, no older fallback after completion or restart")
    }
}
