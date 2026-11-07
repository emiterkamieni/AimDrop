import Cocoa
import Sparkle
import ServiceManagement

@main struct UpdateChecks {
    static func controls(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + controls($0) } }
    static func click(_ title: String, in window: NSWindow) {
        let button = controls(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }!
        button.performClick(nil)
    }
    static let update = AvailableUpdate(version: "0.8.3", downloadURL: URL(string: "https://example.com/update.zip")!,
                                        releasePageURL: URL(string: "https://example.com/release")!, build: "24")

    static func scheduleChecks() {
        let suite = "pl.aimdrop.update-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var completion: UpdateChecker.Completion?
        var probes = 0, notifications = 0
        var allowed = true
        let checker = UpdateChecker(defaults: defaults, clock: { now }, scheduler: { _, _ in {} }, canProbe: { allowed }) {
            probes += 1; completion = $0
        }
        checker.onAvailableUpdate = { _ in notifications += 1 }
        checker.start()
        precondition(probes == 1)
        checker.checkIfDue()
        precondition(probes == 1, "Coalesce wake/activation while probing")
        completion?(.success(.available(update)))
        precondition(notifications == 1)
        now.addTimeInterval(86400)
        checker.checkIfDue(); completion?(.success(.available(update)))
        precondition(notifications == 2, "A failed notification delivery must be retried")
        checker.markNotified(update)
        now.addTimeInterval(86400)
        checker.checkIfDue(); completion?(.success(.available(update)))
        precondition(notifications == 2)
        var next = update; next.build = "25"
        now.addTimeInterval(86400)
        checker.checkIfDue(); completion?(.success(.available(next)))
        precondition(notifications == 3, "A new build with the same displayed version is new")
        checker.markNotified(next); checker.markNotified(update)
        now.addTimeInterval(86400)
        checker.checkIfDue(); completion?(.success(.available(next)))
        precondition(notifications == 3, "A late acknowledgement cannot undo a newer one")
        let before = probes
        now.addTimeInterval(86400); allowed = false
        checker.checkIfDue(); precondition(probes == before)
        allowed = true; checker.checkIfDue(); precondition(probes == before + 1)
        checker.stop(); completion?(.success(.available(update)))
        precondition(notifications == 3, "Stopped schedules ignore stale replies")
        checker.start(); checker.manualCheckStarted()
        now.addTimeInterval(86399); checker.checkIfDue()
        precondition(probes == before + 1)
        now.addTimeInterval(-200000); checker.checkIfDue()
        precondition(probes == before + 1, "A clock correction must not create request bursts")
        checker.stop()
        now.addTimeInterval(86400)
        checker.start()
        checker.manualCheckStarted()
        completion?(.success(.available(update)))
        precondition(notifications == 3, "A joined manual check owns presentation instead of sending a notification")
        checker.stop()
    }

    static func restartChecks() {
        let coordinator = UpdateRestartCoordinator()
        var commands: [[String: Any]] = []
        var uiReady = false, installed = false
        coordinator.send = { commands.append($0); return true }
        coordinator.uiReady = { uiReady }
        coordinator.begin { installed = $0 }
        let id = coordinator.requestID!
        coordinator.receive(["event": "update_status", "request_id": "stale", "idle": true])
        precondition(commands.count == 1)
        coordinator.receive(["event": "update_status", "request_id": id, "idle": true])
        precondition(commands.count == 1, "An open picker/settings draft blocks shutdown")
        uiReady = true; coordinator.advance()
        precondition(commands.last?["command"] as? String == "shutdown_when_idle")
        precondition(!coordinator.canCancel)
        coordinator.receive(["event": "update_status", "request_id": id, "idle": false])
        precondition(coordinator.phase == .waiting && coordinator.canCancel)
        coordinator.receive(["event": "update_status", "request_id": id, "idle": true])
        coordinator.workerExited(success: true)
        precondition(!installed, "Process exit is not a clean shutdown acknowledgement")
        coordinator.receive(["event": "shutdown_complete", "request_id": id])
        precondition(installed && coordinator.phase == .ready)
        coordinator.resetAfterInstallerFailure()
        coordinator.begin { installed = $0 }
        let canceled = coordinator.requestID!
        coordinator.cancel()
        precondition(commands.last?["command"] as? String == "cancel_update")
        coordinator.receive(["event": "update_status", "request_id": canceled, "idle": true])
        precondition(coordinator.phase == .idle)
        coordinator.begin { installed = $0 }
        coordinator.workerExited(success: false)
        precondition(!installed && coordinator.phase == .idle, "An unexpected worker exit cancels the update")
    }

    static func driverChecks() {
        L10n.configure(.polish)
        let driver = SparkleUpdateController()
        var choices: [SPUUserUpdateChoice] = []
        var ready: ((Bool) -> Void)?
        var preparations = 0
        driver.prepareRestart = { preparations += 1; ready = $0 }
        driver.offerForChecks(update) { choices.append($0) }
        precondition(choices.isEmpty && !driver.installing, "Finding an update never grants consent")
        click("Aktualizuj i uruchom ponownie", in: driver.windowForChecks)
        precondition(choices == [.install] && preparations == 0)
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        precondition(preparations == 1 && choices == [.install])
        driver.cancel()
        precondition(choices == [.install, .skip], "Cancel must cancel installation, not install on quit")
        ready?(true)
        precondition(choices == [.install, .skip] && !driver.committed, "Ignore a stale drain callback")
        driver.dismissUpdateInstallation()

        let resumed = SparkleUpdateController()
        choices = []; ready = nil
        resumed.prepareRestart = { ready = $0 }
        resumed.offerForChecks(update, prepared: true) { choices.append($0) }
        precondition(resumed.installing, "Ordinary quit must be gated even before consent for a resumed installer")
        click("Aktualizuj i uruchom ponownie", in: resumed.windowForChecks)
        precondition(choices.isEmpty, "A resumed install must also pass the drain barrier")
        ready?(true)
        precondition(choices == [.install] && resumed.committed)
        resumed.dismissUpdateInstallation()

        let extraction = SparkleUpdateController()
        choices = []
        extraction.offerForChecks(update) { choices.append($0) }
        click("Aktualizuj i uruchom ponownie", in: extraction.windowForChecks)
        extraction.showDownloadDidStartExtractingUpdate()
        extraction.cancel()
        extraction.showReady(toInstallAndRelaunch: { choices.append($0) })
        precondition(choices == [.install, .skip], "Cancel during extraction is honored before restart")
        extraction.dismissUpdateInstallation()

        let translated = SparkleUpdateController()
        translated.offerForChecks(update) { _ in }
        L10n.configure(.english)
        precondition(controls(translated.windowForChecks.contentView!).compactMap { $0 as? NSButton }.contains { $0.title == "Update and Restart" })
        translated.dismissUpdateInstallation()

        let failed = SparkleUpdateController()
        let signature = NSError(domain: "SUSparkleErrorDomain", code: 3002)
        let wrapper = NSError(domain: "SUSparkleErrorDomain", code: 4005, userInfo: [NSUnderlyingErrorKey: signature])
        failed.showUpdaterError(wrapper, acknowledgement: {})
        precondition(controls(failed.windowForChecks.contentView!).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "The update signature is invalid. AimDrop was not replaced. Try again later." })
        failed.dismissUpdateInstallation()
    }

    static func settingsChecks() {
        L10n.configure(.polish)
        let settings = SettingsWindowController(loginItems: LoginItemManager(status: { .notRegistered }, register: {
            throw PreferenceError(message: "registration failed")
        }, unregister: {}, openSettings: {}))
        settings.onSave = { _ in true }
        settings.present(preferences: AppPreferences(language: .polish), status: "")
        let buttons = controls(settings.window!.contentView!).compactMap { $0 as? NSButton }
        buttons.first { $0.title == "Uruchamiaj przy logowaniu" }!.performClick(nil)
        var accepted: Bool?
        settings.resolveForUpdate { accepted = $0 }
        let prompt = NSApp.windows.first { $0 !== settings.window && $0.isVisible && controls($0.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Niezapisane ustawienia" } }!
        click("Zapisz", in: prompt)
        precondition(accepted == false && settings.hasUnsavedChanges && !settings.frozenForUpdate)
        settings.close()
    }

    static func pickerChecks() {
        let suite = "pl.aimdrop.update-picker." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        var commands: [[String: Any]] = []
        app.prepareForChecks(defaults: defaults, preferences: AppPreferences(language: .polish), reservePicker: false) {
            commands.append($0); return true
        }
        defer { app.closeForChecks() }
        let id = UUID().uuidString.lowercased()
        app.eventForChecks(["event": "pending", "transfers": [["id": id, "files": ["example.txt"], "count": 1, "paths": []]]])
        app.requestSaveForChecks(id: id)
        let deadline = Date().addingTimeInterval(3)
        while app.currentFolderIDForChecks == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(app.currentFolderIDForChecks == id)
        var ready = false
        app.prepareUpdateForChecks { ready = $0 }
        let request = commands.last { $0["command"] as? String == "prepare_update" }!["request_id"] as! String
        app.eventForChecks(["event": "update_status", "request_id": request, "idle": true])
        precondition(!commands.contains { $0["command"] as? String == "shutdown_when_idle" })
        precondition(app.currentFolderIDForChecks == id, "The updater must not dismiss the user's picker")
        app.cancelFolderForChecks()
        let stopDeadline = Date().addingTimeInterval(3)
        while !commands.contains(where: { $0["command"] as? String == "shutdown_when_idle" }) && Date() < stopDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(commands.contains { $0["command"] as? String == "shutdown_when_idle" })
        app.eventForChecks(["event": "shutdown_complete", "request_id": request])
        precondition(!ready)
        app.updateWorkerExitedForChecks()
        precondition(ready && app.pendingIDsForChecks.contains(id), "An unsaved receipt survives the restart barrier")
    }

    static func presentationChecks() throws {
        let preview = URL(fileURLWithPath: ".build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        for language in AppLanguage.allCases where language != .system {
            L10n.configure(language)
            let driver = SparkleUpdateController()
            driver.offerForChecks(update) { _ in }
            let window = driver.windowForChecks
            window.contentView!.layoutSubtreeIfNeeded()
            for button in controls(window.contentView!).compactMap({ $0 as? NSButton }).filter({ !$0.isHidden }) {
                let height = button.alignmentRect(forFrame: button.frame).height
                precondition(abs(height - ActionButtonStyle.height) < 0.1,
                             "Button \(button.title): alignment height=\(height), frame=\(button.frame)")
                let rect = button.convert(button.bounds, to: window.contentView)
                precondition(window.contentView!.bounds.contains(rect), "Updater buttons must fit in every language")
            }
            if [.polish, .german, .japanese].contains(language), let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: preview.appendingPathComponent("update-" + language.rawValue + ".png"))
            }
            driver.dismissUpdateInstallation()
        }
    }

    static func trashConfirmationChecks() {
        let suite = "pl.aimdrop.update-trash." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate()
        var commands: [[String: Any]] = []
        app.prepareForChecks(defaults: defaults, preferences: AppPreferences(language: .polish), reservePicker: false) {
            commands.append($0); return true
        }
        defer { app.closeForChecks() }
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        app.eventForChecks(["event": "pending", "transfers": [["id": first, "files": ["first.txt"], "count": 1, "paths": []]]])
        app.requestTrashForChecks(id: first)
        let deadline = Date().addingTimeInterval(3)
        while app.trashAlertForChecks == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(app.trashAlertForChecks != nil)
        app.eventForChecks(["event": "downloaded", "id": second, "files": ["second.txt"], "count": 1, "paths": []])
        let holds = commands.filter { $0["command"] as? String == "hold_transfer" }.count
        app.prepareUpdateForChecks { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(app.trashAlertForChecks == nil && app.currentFolderIDForChecks == nil)
        precondition(commands.filter { $0["command"] as? String == "hold_transfer" }.count == holds,
                     "Dismissing an unconfirmed delete during preparation must not start another picker")
    }

    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        scheduleChecks(); restartChecks(); driverChecks(); settingsChecks(); pickerChecks(); trashConfirmationChecks(); try presentationChecks()
        print("PASS: 24h cadence/migration, notification delivery/dedup, consent, cancellation during extraction/drain, resumed installation, correlated clean shutdown, real picker preservation, settings login failure, live language and 15-language updater layout")
    }
}
