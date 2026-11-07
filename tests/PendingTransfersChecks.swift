import Cocoa

@main struct PendingTransfersChecks {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Inbox UI did not settle")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.aimdrop.pending-checks." + UUID().uuidString
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
        let old = UUID().uuidString.lowercased(), newest = UUID().uuidString.lowercased()
        func receipt(_ id: String, count: Int, time: Double) -> [String: Any] {
            ["id": id, "count": count, "files": (1...count).map { "photo-\($0).jpg" },
             "received_at_ns": time * 1e9, "expires_at_ns": (time + 7 * 86400) * 1e9]
        }
        let first = receipt(old, count: 1, time: 1_800_000_000)
        let second = receipt(newest, count: 12, time: 1_800_000_100)
        let app = makeApp()
        precondition(app.pendingMenuForChecks.submenu!.items[0].title == "Brak niezapisanych transferów")
        app.eventForChecks(["event": "pending", "transfers": [first, second]])
        let menu = app.pendingMenuForChecks
        precondition(menu.title == "Niezapisane transfery (2)")
        let rows = menu.submenu!.items
        precondition(rows[0].representedObject as? String == newest)
        precondition(rows[0].title.hasPrefix("12 elementów — ") && !rows[0].title.contains("photo"))
        let details = rows[0].submenu!.items
        precondition(details.filter { $0.title.hasPrefix("photo-") }.count == 10)
        precondition(details.contains { $0.title == "…i jeszcze 2 elementy" })
        precondition(details.last!.title.hasPrefix("Dostępne do "))
        precondition(rows[1].submenu!.items.last!.title.hasPrefix("Dostępny do "))
        func buttons(in menu: NSMenu) -> [NSButton] {
            menu.items.compactMap(\.view).flatMap(\.subviews).compactMap { $0 as? NSButton }
        }
        let actions = buttons(in: rows[1].submenu!)
        let saveOld = actions.first { $0.title == "Zapisz" }!
        precondition(actions.map(\.title) == ["Zapisz", "Usuń"])
        precondition(actions.allSatisfy { $0.image == nil && $0.imagePosition == .noImage && $0.isEnabled })
        saveOld.performClick(nil)
        wait { app.currentFolderIDForChecks == old }
        precondition(commands.last { $0["command"] as? String == "hold_transfer" }?["id"] as? String == old)
        app.cancelFolderForChecks()
        wait { app.currentFolderIDForChecks == nil }
        precondition(app.pendingIDsForChecks == Set([old, newest]))
        precondition(commands.contains { $0["command"] as? String == "release_transfer" && $0["id"] as? String == old })
        app.eventForChecks(["event": "saving", "id": newest])
        app.eventForChecks(["event": "pending", "transfers": [first]])
        precondition(app.pendingIDsForChecks.contains(newest), "An incomplete busy snapshot must not remove a saving row")
        let busyRow = app.pendingMenuForChecks.submenu!.items.first { $0.representedObject as? String == newest }!
        precondition(buttons(in: busyRow.submenu!).allSatisfy { !$0.isEnabled })
        app.eventForChecks(["event": "complete", "id": newest, "count": 12])
        app.eventForChecks(["event": "pending", "transfers": [first, second]])
        precondition(app.pendingIDsForChecks == [old], "A late snapshot must not resurrect the completed transfer")
        let deleteOld = buttons(in: app.pendingMenuForChecks.submenu!.items[0].submenu!).first { $0.title == "Usuń" }!
        deleteOld.performClick(nil)
        wait { app.trashAlertForChecks != nil }
        precondition(app.trashAlertForChecks!.buttons.map(\.title) == ["Anuluj", "Usuń"])
        app.finishTrashForChecks(delete: false)
        precondition(!commands.contains { $0["command"] as? String == "trash" })
        app.requestTrashForChecks(id: old)
        wait { app.trashAlertForChecks != nil }
        app.finishTrashForChecks(delete: true)
        precondition(commands.contains { $0["command"] as? String == "trash" && $0["token"] is String })
        precondition(app.pendingIDsForChecks.contains(old), "Keep row until worker confirms the move")
        app.eventForChecks(["event": "trashed", "id": old])
        app.eventForChecks(["event": "pending", "transfers": [first]])
        app.eventForChecks(first.merging(["event": "downloaded"]) { _, new in new })
        precondition(app.pendingIDsForChecks.isEmpty)
        app.closeForChecks()

        let restored = makeApp()
        restored.eventForChecks(["event": "pending", "transfers": [first], "latest_received_id": newest])
        precondition(restored.pendingMenuForChecks.submenu!.items.filter { $0.submenu != nil }.count == 1)
        precondition(restored.pendingIDsForChecks == [old], "All unsaved transfers must remain accessible after restart")
        restored.closeForChecks()

        let bulk = makeApp()
        let busy = UUID().uuidString.lowercased(), arriving = UUID().uuidString.lowercased()
        bulk.eventForChecks(["event": "pending", "transfers": [first, second, receipt(busy, count: 1, time: 1_800_000_200)]])
        bulk.eventForChecks(["event": "saving", "id": busy])
        func deleteAllButton() -> NSButton {
            let item = bulk.pendingMenuForChecks.submenu!.items.last!
            return item.view!.subviews.compactMap { $0 as? NSButton }.first!
        }
        let deleteAll = deleteAllButton()
        precondition(deleteAll.title == "Usuń wszystkie" && deleteAll.image == nil && deleteAll.isEnabled)
        deleteAll.performClick(nil)
        wait { bulk.trashAlertForChecks != nil }
        precondition(bulk.trashAlertForChecks!.informativeText.contains("2"))
        bulk.finishTrashForChecks(delete: false)
        precondition(!commands.contains { $0["command"] as? String == "trash_many" })
        deleteAllButton().performClick(nil)
        wait { bulk.trashAlertForChecks != nil }
        bulk.eventForChecks(["event": "pending", "transfers": [receipt(arriving, count: 1, time: 1_800_000_300)]])
        bulk.finishTrashForChecks(delete: true)
        let batch = commands.last { $0["command"] as? String == "trash_many" }!
        precondition(Set(batch["ids"] as! [String]) == Set([old, newest]), "Bulk delete must exclude busy transfers and arrivals after confirmation opened")
        bulk.eventForChecks(["event": "trashed", "id": old])
        bulk.eventForChecks(["event": "trash_many_result", "request_id": batch["request_id"]!, "started": [old, newest], "skipped": []])
        bulk.eventForChecks(["event": "trashed", "id": newest])
        precondition(bulk.pendingIDsForChecks == Set([busy, arriving]))
        bulk.eventForChecks(["event": "saving", "id": arriving])
        precondition(!deleteAllButton().isEnabled)
        bulk.closeForChecks()
        print("PASS: per-transfer queue, count/date titles, first ten names, singular/plural deadlines, picker hold/release, busy snapshots, save/trash acknowledgements, confirmation cancellation and restart")
        print("PASS: bulk Trash confirmation/cancellation, busy transfer protection, arrival snapshot and out-of-order acknowledgement")
    }
}
