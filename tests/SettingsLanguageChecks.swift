import Cocoa
import ServiceManagement

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
        legacy.removeValue(forKey: "updateNotifications")
        for code in [nil, "future-language"] as [String?] {
            legacy["language"] = code
            let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
            precondition(restored.language == .system && restored.receiverName == "Studio" && !restored.completionSound)
            precondition(restored.updateNotifications, "Previous installations retain enabled update notifications")
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
        let notifications = descendants(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "updateNotifications" }!
        precondition(notifications.state == .on)
        notifications.performClick(nil)
        precondition(commands.isEmpty, "Notification changes are drafts until Save")
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: .french)!)
        NSApp.sendAction(language.action!, to: language.target, from: language)
        precondition(L10n.languageCode == "pl" && commands.isEmpty, "Language selection is a draft until Save")
        settings.close()
        _ = app.showSettingsForChecks()
        precondition(language.indexOfSelectedItem == AppLanguage.allCases.firstIndex(of: .polish)!)
        precondition(notifications.state == .on, "Closing discards the notification draft")
        notifications.performClick(nil)
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: .french)!)
        NSApp.sendAction(language.action!, to: language.target, from: language)
        save.performClick(nil)
        precondition(L10n.languageCode == "fr" && settings.window!.title != originalTitle)
        precondition(PreferencesStore(defaults: defaults).load().language == .french)
        precondition(!PreferencesStore(defaults: defaults).load().updateNotifications)
        precondition(commands.count == 1 && commands[0]["command"] as? String == "set_language" && commands[0]["language"] as? String == "fr")
        precondition(app.appliedNameForChecks == "Studio" && app.appliedAvatarForChecks == originalAvatar, "A language change must not change the receiver profile")
        settings.close()
        precondition(app.validateMenuItem(app.updateItemForChecks), "Manual updates remain available with notifications off")
        print("PASS: backward-compatible preferences, notification Save/cancel, language IPC without pairing changes, manual updates with notifications off")

        let previews = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var loginStatus = SMAppService.Status.notRegistered
        let manager = LoginItemManager(status: { loginStatus }, register: {}, unregister: {}, openSettings: {})
        let preview = SettingsWindowController(loginItems: manager)
        defer { preview.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
          preview.window?.appearance = NSAppearance(named: appearance)
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
            precondition(languageMenu.frame.width <= 230, "Language popup should stay compact")
            precondition(!buttons.contains { $0.identifier?.rawValue == "checkForUpdates" })
            checkLayout(content)
            content.wantsLayer = true
            preview.window?.appearance?.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                preview.window?.appearance?.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                }
                let suffix = appearance == .darkAqua ? "-dark" : ""
                try bitmap.representation(using: .png, properties: [:])?.write(to: previews.appendingPathComponent("settings-\(language.rawValue)\(suffix).png"))
            }
            let automatic = buttons.first { $0.identifier?.rawValue == "automaticSave" }!
            automatic.performClick(nil)
            loginStatus = .requiresApproval
            preview.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: preview.window))
            preview.setStatus(String(repeating: "Long validation feedback. ", count: 10), error: true)
            content.layoutSubtreeIfNeeded()
            checkLayout(content)
            let folder = descendants(content).first { $0.identifier?.rawValue == "automaticSaveFolder" }!
            precondition(!folder.isHidden)
            loginStatus = .notRegistered
            preview.close()
          }
        }
        L10n.configure(.english)
        preview.relocalize()
        preview.present(preferences: AppPreferences(language: .english), status: "")
        preview.setStatus(String(repeating: "Extended validation feedback.\n", count: 1000), error: true)
        let content = preview.window!.contentView!
        content.layoutSubtreeIfNeeded()
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.documentView!.frame.height > scroll.contentSize.height)
        precondition(preview.window!.frame.height <= preview.window!.screen!.visibleFrame.height + 1)
        checkLayout(content)
        scroll.documentView!.scroll(NSPoint(x: 0, y: scroll.documentView!.frame.maxY))
        checkLayout(content)
        preview.close()
        print("PASS: 15-language light/dark settings, compact controls, automatic destination and expanded feedback/login states")
    }

    static func checkLayout(_ content: NSView) {
        let document = descendants(content).compactMap { $0 as? NSScrollView }.first?.documentView
        for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor {
            if let button = view as? NSButton {
                precondition(button.fittingSize.width <= button.frame.width + 1, "Clipped control: \(button.title)")
                let container = document.flatMap { button.isDescendant(of: $0) ? $0 : nil } ?? content
                let frame = button.convert(button.bounds, to: container)
                precondition(container.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Control outside Settings: \(button.title)")
            }
        }
    }
}
