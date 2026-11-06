import Cocoa

@main struct SettingsLanguageChecks {
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.aimdrop.language-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = AppPreferences(receiverName: "Studio", completionSound: false, language: .polish)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
        legacy.removeValue(forKey: "language")
        for code in [nil, "future-language"] as [String?] {
            legacy["language"] = code
            let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
            precondition(restored.language == .system && restored.receiverName == "Studio" && !restored.completionSound)
        }
        let app = AppDelegate()
        var commands: [[String: Any]] = []
        app.prepareForChecks(defaults: defaults, preferences: preferences, storageDirectory: root, reservePicker: false) {
            commands.append($0); return true
        }
        defer { app.closeForChecks() }
        let originalAvatar = app.appliedAvatarForChecks
        let settings = app.showSettingsForChecks()
        let view = settings.window!.contentView!
        let language = descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "appLanguage" }!
        let save = descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Zapisz" }!
        let originalTitle = settings.window!.title
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: .french)!)
        NSApp.sendAction(language.action!, to: language.target, from: language)
        precondition(L10n.languageCode == "pl" && commands.isEmpty, "Language selection is a draft until Save")
        settings.close()
        _ = app.showSettingsForChecks()
        precondition(language.indexOfSelectedItem == AppLanguage.allCases.firstIndex(of: .polish)!)
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: .french)!)
        NSApp.sendAction(language.action!, to: language.target, from: language)
        save.performClick(nil)
        precondition(L10n.languageCode == "fr" && settings.window!.title != originalTitle)
        precondition(PreferencesStore(defaults: defaults).load().language == .french)
        precondition(commands.count == 1 && commands[0]["command"] as? String == "set_language" && commands[0]["language"] as? String == "fr")
        precondition(app.appliedNameForChecks == "Studio" && app.appliedAvatarForChecks == originalAvatar, "A language change must not change the receiver profile")
        settings.close()
        let available = AvailableUpdate(version: "99.0.0", downloadURL: URL(string: "https://github.com/emiterkamieni/AimDrop/releases/tag/v99.0.0")!, releasePageURL: URL(string: "https://github.com/emiterkamieni/AimDrop/releases/tag/v99.0.0")!)
        app.updateResultForChecks(.success(.available(available)))
        precondition(app.updateAlertForChecks?.buttons.count == 2)
        precondition(app.updateAlertForChecks?.informativeText == L10n.text("Download the new version from GitHub.", "Pobierz nową wersję z GitHuba."))
        app.dismissUpdateForChecks()
        app.updateResultForChecks(.success(.upToDate))
        precondition(app.updateAlertForChecks?.buttons.count == 1)
        app.dismissUpdateForChecks()
        print("PASS: backward-compatible language preferences, draft/cancel, live language IPC without pairing changes, localized update results")

        let previews = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let manager = LoginItemManager(status: { .notRegistered }, register: {}, unregister: {}, openSettings: {})
        let preview = SettingsWindowController(loginItems: manager)
        preview.window?.appearance = NSAppearance(named: .aqua)
        defer { preview.close() }
        for language in AppLanguage.allCases where language != .system {
            L10n.configure(language)
            preview.relocalize()
            preview.present(preferences: AppPreferences(language: language), status: "")
            preview.window?.makeFirstResponder(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let content = preview.window!.contentView!
            content.layoutSubtreeIfNeeded()
            let buttons = descendants(content).compactMap { $0 as? NSButton }
            let close = buttons.first { $0.action == NSSelectorFromString("closeSettings") }!
            let languageMenu = descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "appLanguage" }!
            precondition(languageMenu.fittingSize.width <= languageMenu.frame.width + 1,
                         "Language control clips in \(language.rawValue): \(languageMenu.frame.width) < \(languageMenu.fittingSize.width)")
            precondition(close.fittingSize.width <= close.frame.width + 1,
                         "Close button clips in \(language.rawValue): \(close.frame.width) < \(close.fittingSize.width)")
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                preview.window?.appearance?.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                }
                try bitmap.representation(using: .png, properties: [:])?.write(to: previews.appendingPathComponent("settings-\(language.rawValue).png"))
            }
            preview.close()
        }
        print("PASS: settings rendered in all 15 languages")
    }
}
