import Cocoa

@main struct WindowPlacementChecks {
    static func checkCentered(_ window: NSWindow, on screen: NSScreen) {
        precondition(abs(window.frame.midX - screen.visibleFrame.midX) <= 1)
        precondition(abs(window.frame.midY - screen.visibleFrame.midY) <= 1)
        precondition(screen.visibleFrame.contains(window.frame), "The complete dialog must be on screen")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let suite = "pl.aimdrop.window-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        app.prepareForChecks(defaults: defaults, preferences: AppPreferences(language: .polish), reservePicker: false) { _ in true }
        defer { app.closeForChecks() }

        for visible in [NSRect(x: -1920, y: 24, width: 1920, height: 1030),
                        NSRect(x: 0, y: -1200, width: 1600, height: 1150),
                        NSRect(x: 60, y: 1080, width: 2500, height: 1380)] {
            let size = NSSize(width: 360, height: 270)
            let frame = NSRect(origin: WindowPlacement.centeredOrigin(for: size, in: visible), size: size)
            precondition(visible.contains(frame))
            precondition(frame.midX == visible.midX && frame.midY == visible.midY)
        }
        let available = AvailableUpdate(version: "99.0.0",
            downloadURL: URL(string: "https://github.com/emiterkamieni/AimDrop/releases/tag/v99.0.0")!,
            releasePageURL: URL(string: "https://github.com/emiterkamieni/AimDrop/releases/tag/v99.0.0")!)
        let results: [Result<UpdateCheckResult, Error>] = [.success(.upToDate), .success(.available(available)),
                                                         .success(.noReleases), .failure(UpdateCheckError.timedOut)]
        for screen in NSScreen.screens {
            for result in results {
                app.updateResultForChecks(result, on: screen)
                checkCentered(app.updateAlertForChecks!.window, on: screen)
                app.dismissUpdateForChecks()
            }
        }

        let settings = app.showSettingsForChecks()
        checkCentered(settings.window!, on: WindowPlacement.activeScreen()!)
        // An update result arriving while the folder sheet is open keeps its
        // target display and waits until the sheet closes.
        let controls = descendants(settings.window!.contentView!)
        let automatic = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "automaticSave" }!
        automatic.performClick(nil)
        let choose = descendants(settings.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("chooseFolder") }!
        choose.performClick(nil)
        precondition(settings.isChoosingFile)
        let sheetDeadline = Date().addingTimeInterval(3)
        while settings.window?.attachedSheet == nil && Date() < sheetDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(settings.window?.attachedSheet is NSOpenPanel)
        let target = NSScreen.screens.last!
        app.updateResultForChecks(.success(.upToDate), on: target)
        precondition(app.updateAlertForChecks == nil)
        precondition(!app.validateMenuItem(app.updateItemForChecks), "A deferred result must retain its display until presented")
        (settings.window?.attachedSheet as? NSOpenPanel)?.cancel(nil)
        let deadline = Date().addingTimeInterval(3)
        while app.updateAlertForChecks == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        checkCentered(app.updateAlertForChecks!.window, on: target)
        app.dismissUpdateForChecks()
        precondition(app.validateMenuItem(app.updateItemForChecks))
        settings.close()

        let aboutScreen = WindowPlacement.activeScreen()!
        guard let about = app.showAboutForChecks() else { fatalError("The standard About panel was not captured") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        checkCentered(about, on: aboutScreen)
        about.setFrameOrigin(aboutScreen.visibleFrame.origin)
        about.close()
        precondition(app.showAboutForChecks() === about)
        checkCentered(about, on: aboutScreen)
        print("PASS: centered update results and About panel, negative/stacked displays, deferred sheet presentation and reopening")
    }

    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
