import Cocoa

@main
struct SettingsChecks {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(condition(), "Timed out waiting for settings/event routing")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.airfolder.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        precondition(store.load() == AppPreferences(), "First launch must ask for a folder and enable completion sound")
        let unicodeName = try AppPreferences.normalizedName("  Z\u{0307}o\u{0301}łw 👩‍💻  ")
        precondition(unicodeName == "Żółw 👩‍💻")
        for name in ["", "   ", "Name\n", "Name\u{0085}", "Name\u{202e}", String(repeating: "😀", count: 33)] {
            do { _ = try AppPreferences.normalizedName(name); fatalError("Invalid name accepted") }
            catch is PreferenceError { }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airfolder-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var folder = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var preferences = AppPreferences(receiverName: "Studio 📥", automaticSave: true,
                                         destination: try SaveDestination(url: folder), completionSound: false)
        try store.save(preferences)
        precondition(PreferencesStore(defaults: defaults).load() == preferences, "All settings must survive a fresh store instance")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
        legacy.removeValue(forKey: "avatarPNG")
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded == preferences, "Existing preferences must decode without an avatar field")

        let app = AppDelegate()
        var commands: [[String: Any]] = []
        var acceptsCommands = true
        app.prepareForChecks(defaults: defaults, preferences: preferences, storageDirectory: root.appendingPathComponent("Support")) { command in
            commands.append(command)
            return acceptsCommands
        }
        defer { app.closeForChecks() }
        func receipt(_ id: String) -> [String: Any] {
            ["id": id, "count": 1, "files": ["file.txt"], "paths": [root.appendingPathComponent("file.txt").path]]
        }
        func downloaded(_ id: String) -> [String: Any] {
            receipt(id).merging(["event": "downloaded"]) { _, new in new }
        }
        func saves(_ id: String) -> [[String: Any]] { commands.filter { $0["command"] as? String == "save" && $0["id"] as? String == id } }
        let old = UUID().uuidString
        app.eventForChecks(["event": "pending", "transfers": [receipt(old)]])
        precondition(commands.isEmpty, "Restored/deferred transfers must not be automatically saved")

        let manualClaim = UUID().uuidString
        app.eventForChecks(["event": "pending", "transfers": [receipt(manualClaim)]])
        app.requestSaveForChecks(id: manualClaim)
        app.eventForChecks(downloaded(manualClaim))
        precondition(saves(manualClaim).isEmpty, "A delayed download must not override a user's manual save/deferral workflow")

        let relocated = root.appendingPathComponent("Moved destination")
        try FileManager.default.moveItem(at: folder, to: relocated)
        folder = relocated

        let fresh = UUID().uuidString
        app.eventForChecks(downloaded(fresh))
        wait { saves(fresh).count == 1 }
        let savedDirectory = URL(fileURLWithPath: saves(fresh)[0]["directory"] as! String)
        precondition(savedDirectory.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath(),
                     "Automatic save must target the selected directory, including /var vs /private/var aliases")
        precondition(store.load().destination?.displayPath == savedDirectory.path,
                     "Settings must refresh the displayed path when the bookmarked folder moves")
        preferences = store.load()
        app.eventForChecks(downloaded(fresh))
        app.eventForChecks(["event": "save_canceled", "id": fresh])
        app.eventForChecks(["event": "pending", "transfers": [receipt(old), receipt(fresh)]])
        app.eventForChecks(downloaded(fresh))
        precondition(saves(fresh).count == 1 && app.pendingIDsForChecks.contains(fresh), "Cancel/duplicate events must retain the buffer without retrying")

        let failed = UUID().uuidString
        acceptsCommands = false
        app.eventForChecks(downloaded(failed))
        wait { saves(failed).count == 1 && !app.savingIDsForChecks.contains(failed) }
        app.eventForChecks(downloaded(failed))
        precondition(saves(failed).count == 1 && app.pendingIDsForChecks.contains(failed), "Closed command channel must release reservation and retain pending files")
        acceptsCommands = true

        // A removed destination must not silently fall back to a cached path or be recreated.
        try FileManager.default.removeItem(at: folder)
        let missing = UUID().uuidString
        app.eventForChecks(downloaded(missing))
        wait { !app.savingIDsForChecks.contains(missing) }
        precondition(saves(missing).isEmpty && app.pendingIDsForChecks.contains(missing))
        precondition(!FileManager.default.fileExists(atPath: folder.path))

        preferences.automaticSave = false
        preferences.receiverName = "Pierwsza nazwa"
        app.preferencesForChecks(preferences)
        let firstCommand = commands.last { $0["command"] as? String == "set_profile" }!
        let first = firstCommand["request_id"] as! String
        preferences.receiverName = "Druga nazwa"
        app.preferencesForChecks(preferences)
        let secondCommand = commands.last { $0["command"] as? String == "set_profile" }!
        let second = secondCommand["request_id"] as! String
        app.eventForChecks(["event": "profile_result", "request_id": first, "ok": true, "name": "Pierwsza nazwa", "avatar_digest": firstCommand["avatar_digest"]!])
        precondition(app.appliedNameForChecks == "Studio 📥", "A late obsolete acknowledgement must not change the menu")
        app.eventForChecks(["event": "profile_result", "request_id": second, "ok": true, "name": "Druga nazwa", "avatar_digest": secondCommand["avatar_digest"]!])
        precondition(app.appliedNameForChecks == "Druga nazwa" && store.load().receiverName == "Druga nazwa")
        let manual = UUID().uuidString
        app.eventForChecks(downloaded(manual))
        precondition(saves(manual).isEmpty && app.pendingIDsForChecks.contains(manual), "Ask mode must not automatically save")
        precondition(saves(old).isEmpty, "Changing preferences must not consume the restored backlog")
        let custom = try ReceiverAvatar.read(at: URL(fileURLWithPath: ".build/avatar-fixtures/avatar.png"))
        let profileCount = commands.count
        preferences.avatarPNG = custom.png
        app.preferencesForChecks(preferences)
        let avatarCommand = commands.last!
        precondition(commands.count == profileCount + 1 && avatarCommand["command"] as? String == "set_profile")
        precondition(avatarCommand["name"] as? String == "Druga nazwa" && avatarCommand["avatar_digest"] as? String == custom.digest)
        let cachedAvatar = try ReceiverAvatar.read(at: URL(fileURLWithPath: avatarCommand["avatar_path"] as! String))
        precondition(cachedAvatar.png == custom.png)
        app.preferencesForChecks(preferences)
        precondition(commands.count == profileCount + 1, "An equal pending profile must not be resent")
        app.eventForChecks(["event": "profile_result", "request_id": avatarCommand["request_id"]!, "ok": true, "name": preferences.receiverName, "avatar_digest": custom.digest])
        precondition(app.appliedAvatarForChecks == custom.digest && store.load().avatarPNG == custom.png)
        var corrupt = preferences; corrupt.avatarPNG = Data("bad png".utf8)
        defaults.set(try JSONEncoder().encode(corrupt), forKey: "AirFolderPreferences.v1")
        precondition(store.load().receiverName == preferences.receiverName, "Bad artwork must not reset unrelated preferences")
        try store.save(preferences)
        print("PASS: settings persistence, Unicode validation, new-only autosave, cancel/failure/detached-folder retention, duplicate events, correlated rename acknowledgements")

        let controller = SettingsWindowController()
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.present(preferences: preferences, status: "Ustawienia zapisane.")
        guard let view = controller.window?.contentView else { fatalError("No settings content") }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = descendants(view).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "receiverName" }!
        controller.window?.makeFirstResponder(field)
        let editor = field.currentEditor() as! NSTextView
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
                                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        if NSApp.keyWindow === controller.window {
            precondition(NSApp.mainMenu?.performKeyEquivalent(with: selectAll) == true)
        } else {
            // A CLI-launched test may not steal focus on modern macOS. Validate
            // the installed menu action against the real editor explicitly.
            let item = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }
                .first { $0.keyEquivalent == "a" }!
            precondition(item.target == nil)
            precondition(NSApp.sendAction(item.action!, to: editor, from: item))
        }
        precondition(editor.selectedRange().length == field.stringValue.utf16.count,
                     "Standard editing shortcuts must reach the receiver-name field")
        print("PASS: standard Edit menu action operates on the native settings text editor")
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if CommandLine.arguments.count == 2,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        let resetAvatar = buttons.first { $0.title == "Przywróć logo" }!
        let chooseAvatar = buttons.first { $0.title == "Wybierz zdjęcie…" }!
        let saveSettings = buttons.first { $0.title == "Zapisz" }!
        var saved: [AppPreferences] = []
        controller.onSave = { saved.append($0); return true }
        resetAvatar.performClick(nil)
        precondition(saved.isEmpty, "Reset must only change the settings draft")
        controller.close()
        controller.present(preferences: preferences, status: "")
        saveSettings.performClick(nil)
        precondition(saved.last?.avatarPNG == custom.png, "Closing unsaved settings must discard a draft avatar reset")
        chooseAvatar.performClick(nil)
        wait { controller.isChoosingFile && controller.window?.attachedSheet != nil }
        (controller.window?.attachedSheet as? NSOpenPanel)?.cancel(nil)
        wait { !controller.isChoosingFile }
        saveSettings.performClick(nil)
        precondition(saved.last?.avatarPNG == custom.png, "Image picker Cancel must preserve the previous avatar")

        let image = try ReceiverAvatar.source(at: URL(fileURLWithPath: ".build/avatar-fixtures/avatar.png"))
        let crop = AvatarCropWindowController(image: image)
        crop.window?.appearance = NSAppearance(named: .aqua)
        var cropFinished = false
        var cropResult: ReceiverAvatar?
        crop.present(on: controller.window!) { cropResult = $0; cropFinished = true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        if let cropView = crop.window?.contentView,
           let bitmap = cropView.bitmapImageRepForCachingDisplay(in: cropView.bounds) {
            cropView.wantsLayer = true
            cropView.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
            cropView.cacheDisplay(in: cropView.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/avatar-crop-check.png"))
        }
        NSApp.sendAction(NSSelectorFromString("cancel"), to: crop, from: nil)
        wait { cropFinished }
        precondition(cropResult == nil, "Crop Cancel must not export a replacement")
        resetAvatar.performClick(nil)
        saveSettings.performClick(nil)
        precondition(saved.last?.avatarPNG == nil, "Reset is committed only when settings are saved")
        print("PASS: circular avatar draft, unsaved reset rollback, image picker cancellation, crop cancellation, explicit default-logo save")
        controller.close()
    }
}
