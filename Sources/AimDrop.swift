import Cocoa

// The receiver owns the network; AppKit owns the folder chooser on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nameLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pendingMenu = PendingTransfersMenu()
    private let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var statusText: () -> String = { L10n.text("Starting…", "Uruchamianie…") }
    private var statusIsReady = false
    private var discoveryStatus: String?
    private var activeLanguageCode = ""
    private lazy var sparkleUpdater = SparkleUpdateController()
    private lazy var updater = UpdateChecker(canProbe: { [weak self] in self?.sparkleUpdater.busy == false },
                                             probe: { [weak self] completion in self?.sparkleUpdater.probe(completion) })
    private let updateRestart = UpdateRestartCoordinator()
    private var settingsResolvedForUpdate = false
    private var resolvingUpdateSettings = false
    private var updateSettingsFailed = false
    private var languageRequestID: String?
    private weak var aboutWindow: NSWindow?
    private var worker: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var logHandle: FileHandle?
    private var panel: NSOpenPanel?
    private var currentOffer: String?
    private var pendingTransfers: [String: [String: Any]] = [:]
    private var pendingOrder: [String] = []
    private var promptedTransfers = Set<String>()
    private var savingTransfers = Set<String>()
    private var trashingTransfers = Set<String>()
    private var trashFailures = Set<String>()
    private enum HoldAction { case save, trash, automatic(SaveDestination) }
    private var holdRequests: [String: (id: String, action: HoldAction)] = [:]
    private var heldTransfers: [String: String] = [:]
    private var choosingRequest: String?
    private var trashAlert: NSAlert?
    private var trashOfferID: String?
    private var trashAllOfferIDs: [String] = []
    private var bulkTrashRequests: [String: Set<String>] = [:]
    private var retentionRequestID: String?
    private var completedTransfers = Set<String>()
    private var handledDownloads = Set<String>()
    private var manuallyHandledTransfers = Set<String>()
    private var requestedSaveID: String?
    private var lastFolder: URL?
    private var quitting = false
    private var reportedFatalError = false
    private var errorAlert: NSAlert?
    private var deferredError: (String, String)?
    private var preferenceStore = PreferencesStore()
    private lazy var preferences = preferenceStore.load()
    private var settingsWindow: SettingsWindowController?
    private var settingsStatus = ""
    private var appliedReceiverName: String?
    private var appliedAvatarDigest: String?
    private var pendingProfileRequest: (id: String, name: String, digest: String)?
    private var workerReady = false
    private var inboxLoaded = false
    private let destinationQueue = DispatchQueue(label: "pl.airfolder.destination", qos: .utility)
    private let ioQueue = DispatchQueue(label: "pl.airfrajer.events")
    private var buffer = Data()
    private let logFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var receiverName: String { preferences.receiverName }
    private let notifications = TransferNotifications()
    private let progressBanners = TransferProgressBanners()
    private lazy var pairingWindow = PairingWindowController()
    #if AIRFOLDER_CHECKS
    private var commandForChecks: (([String: Any]) -> Bool)?
    private var storageForChecks: URL?
    private var automaticHoldsForChecks = true
    #endif

    private var supportDirectory: URL {
        #if AIMDROP_UPDATE_EXPERIMENT
        if let config = Bundle.main.object(forInfoDictionaryKey: "AimDropUpdateExperiment") as? [String: String], let path = config["state"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        #if AIRFOLDER_CHECKS
        if let storageForChecks { return storageForChecks }
        #endif
        // Stable storage identity across application renames.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirFrajer", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.configure(preferences.language)
        activeLanguageCode = L10n.languageCode
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AimDropArtwork.applicationIcon
        setupMenu()
        let existingInstallation = preferenceStore.hasSavedPreferences
            || FileManager.default.fileExists(atPath: supportDirectory.path)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let logURL = supportDirectory.appendingPathComponent("receiver.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()
            do {
                #if AIMDROP_UPDATE_EXPERIMENT
                if let config = Bundle.main.object(forInfoDictionaryKey: "AimDropUpdateExperiment") as? [String: String], config["install"] == "yes", let login = config["login"] {
                    try LoginItemManager.system.setEnabled(login == "on")
                }
                #endif
                try LoginItemManager.system.enableByDefaultIfNeeded(existingInstallation: existingInstallation)
            } catch {
                log("Default login item registration failed")
                setSettingsStatus(L10n.format("Could not change launch at login: %@", "Nie udało się zmienić autostartu: %@", error.localizedDescription), error: true)
            }
            log("Login item status=\(LoginItemManager.system.status().rawValue)")
            notifications.log = { [weak self] message in self?.log(message) }
            progressBanners.log = { [weak self] message in self?.log(message) }
            notifications.setUpdateNotificationsEnabled(preferences.updateNotifications)
            notifications.start()
            notifications.onSavePending = { [weak self] id in self?.requestSave(id: id) }
            notifications.onOpenUpdate = { [weak self] _ in self?.checkForUpdates() }
            progressBanners.onCancel = { [weak self] id, saving in
                guard let self = self else { return }
                self.send(["command": saving ? "cancel_save" : "cancel_transfer", "id": id])
            }
            try startWorker()
        } catch {
            showError(L10n.text("Could not start the receiver", "Nie można uruchomić odbiornika"), error.localizedDescription)
            setReceiverStatus("Startup failed", "Błąd uruchamiania")
        }
        configureUpdates()
        updater.onAvailableUpdate = { [weak self] update in
            guard let self, !self.quitting, self.preferences.updateNotifications else { return }
            self.notifications.updateAvailable(version: update.version, url: update.downloadURL) { [weak self] delivered in
                if delivered { self?.updater.markNotified(update) }
            }
        }
        #if AIMDROP_UPDATE_EXPERIMENT
        startUpdateExperiment()
        #else
        updater.start()
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(systemLanguageOrWakeChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemLanguageOrWakeChanged), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard statusItem != nil, !quitting else { return }
        L10n.configure(preferences.language)
        refreshLanguage()
        updater.checkIfDue()
    }

    @objc private func systemLanguageOrWakeChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.quitting else { return }
            L10n.configure(self.preferences.language)
            self.refreshLanguage()
            self.updater.checkIfDue()
            if self.workerReady { self.send(["command": "maintain_inbox"]) }
        }
    }

    private func setReceiverStatus(_ english: String, _ polish: String, _ arguments: CVarArg...) {
        statusIsReady = english == "Ready to receive"
        statusText = {
            let value = L10n.text(english, polish)
            return arguments.isEmpty ? value : String(format: value, locale: L10n.locale, arguments: arguments)
        }
        refreshStatusLine()
    }

    private func refreshStatusLine() {
        let availability: String?
        switch discoveryStatus {
        case "waiting": availability = L10n.text("Waiting for Wi-Fi…", "Oczekiwanie na Wi-Fi…")
        case "retrying": availability = L10n.text("Restoring receiver visibility…", "Przywracanie widoczności odbiornika…")
        default: availability = nil
        }
        if workerReady, let availability {
            statusLine.title = statusIsReady ? availability : statusText() + " · " + availability
        } else { statusLine.title = statusText() }
    }

    private func refreshLanguage() {
        let code = L10n.languageCode
        guard code != activeLanguageCode else { return }
        activeLanguageCode = code
        setupMenu()
        settingsWindow?.relocalize()
        notifications.refreshCategories()
        if workerReady { synchronizeLanguage() }
    }

    private func setupMenu() {
        setupApplicationMenu()
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        statusItem.menu?.removeAllItems()
        statusItem.button?.image = AimDropArtwork.menuBarIcon()
        statusItem.button?.toolTip = L10n.text("AimDrop — receive AirDrop into a folder you choose", "AimDrop — odbierz AirDrop do wybranego folderu")
        let menu = NSMenu()
        refreshReceiverName()
        refreshStatusLine()
        menu.addItem(nameLine)
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pendingMenu.onSave = { [weak self] id in self?.requestSave(id: id) }
        pendingMenu.onTrash = { [weak self] id in self?.requestTrash(id: id) }
        pendingMenu.onTrashAll = { [weak self] ids in self?.requestTrashAll(ids: ids) }
        pendingMenu.canAct = { [weak self] id in self?.canHandleTransfer(id) ?? false }
        refreshPendingMenu()
        menu.addItem(pendingMenu.item)
        addItem(L10n.text("Show Last Folder", "Pokaż ostatni folder"), #selector(openLastFolder), to: menu)
        menu.addItem(.separator())
        let settings = addItem(L10n.text("Settings…", "Ustawienia…"), #selector(showSettings), to: menu)
        settings.keyEquivalent = ","
        updateItem.title = L10n.text("Check for Updates…", "Sprawdź aktualizacje…")
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        menu.addItem(updateItem)
        addItem(L10n.text("About AimDrop", "O AimDrop"), #selector(showAbout), to: menu)
        menu.addItem(.separator())
        let quit = addItem(L10n.text("Quit AimDrop", "Zakończ AimDrop"), #selector(quitApp), to: menu)
        quit.keyEquivalent = "q"
        statusItem.menu = menu
    }

    private func setupApplicationMenu() {
        // Accessory apps still need a responder-chain Edit menu for text shortcuts.
        let main = NSMenu()
        let application = NSMenuItem(title: "AimDrop", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "AimDrop")
        addItem(L10n.text("About AimDrop", "O AimDrop"), #selector(showAbout), to: applicationMenu)
        addItem(L10n.text("Settings…", "Ustawienia…"), #selector(showSettings), to: applicationMenu).keyEquivalent = ","
        applicationMenu.addItem(.separator())
        addItem(L10n.text("Quit AimDrop", "Zakończ AimDrop"), #selector(quitApp), to: applicationMenu).keyEquivalent = "q"
        application.submenu = applicationMenu
        main.addItem(application)
        let edit = NSMenuItem(title: L10n.text("Edit", "Edycja"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.text("Edit", "Edycja"))
        for (title, action, key) in [(L10n.text("Undo", "Cofnij"), "undo:", "z"), (L10n.text("Cut", "Wytnij"), "cut:", "x"),
                                      (L10n.text("Copy", "Kopiuj"), "copy:", "c"), (L10n.text("Paste", "Wklej"), "paste:", "v"),
                                      (L10n.text("Select All", "Zaznacz wszystko"), "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    @discardableResult private func addItem(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func startWorker() throws {
        discoveryStatus = nil
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "AimDrop", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Application resources are missing.", "Brak zasobów aplikacji.")])
        }
        let process = Process()
        let avatar = try selectedAvatar(preferences)
        let avatarPath = try materializeAvatar(preferences, avatar: avatar)
        let python = Bundle.main.object(forInfoDictionaryKey: "AFPythonExecutable") as? String ?? "/usr/bin/python3"
        process.executableURL = python.hasPrefix("/") ? URL(fileURLWithPath: python) : resources.appendingPathComponent(python)
        process.environment = ProcessInfo.processInfo.environment.merging(["AIMDROP_LANGUAGE": L10n.languageCode]) { _, new in new }
        process.arguments = ["-I", "-B", "-u", resources.appendingPathComponent("receiver/main.py").path,
                             "--name=\(receiverName)", "--language", L10n.languageCode, "--state-dir", supportDirectory.path,
                             "--native-helper", resources.deletingLastPathComponent().appendingPathComponent("MacOS/AimDropReceiver").path,
                             "--native-artwork", resources.appendingPathComponent("AimDropAvatar.png").path,
                             "--avatar-digest", avatar.digest,
                             "--trash-helper", resources.deletingLastPathComponent().appendingPathComponent("MacOS/AimDropTrash").path,
                             "--retention-days", String(preferences.retentionDays)]
        if !preferences.automaticTrash { process.arguments?.append("--disable-auto-trash") }
        if let avatarPath { process.arguments?.append(contentsOf: ["--native-avatar", avatarPath]) }
        #if AIMDROP_UPDATE_EXPERIMENT
        process.arguments?.append("--native-loopback")
        #endif
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = logHandle
        input = stdinPipe.fileHandleForWriting
        outputPipe = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async { [weak self] in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, !self.quitting else { return }
                if self.updateRestart.active {
                    self.workerReady = false
                    self.updateRestart.workerExited(success: proc.terminationStatus == 0)
                    return
                }
                self.workerReady = false
                self.pairingWindow.close()
                self.pendingProfileRequest = nil
                self.savingTransfers.removeAll()
                self.trashingTransfers.removeAll()
                self.holdRequests.removeAll()
                self.heldTransfers.removeAll()
                self.choosingRequest = nil
                self.trashAlert?.window.close()
                self.trashAlert = nil; self.trashOfferID = nil
                self.trashAllOfferIDs.removeAll(); self.bulkTrashRequests.removeAll()
                self.pendingMenu.hidePreview()
                self.refreshPendingMenu()
                self.setSettingsStatus(L10n.text("The receiver is stopped. Settings will be used the next time it starts.", "Odbiornik jest zatrzymany. Ustawienia zostaną użyte przy następnym uruchomieniu."))
                self.panel?.cancel(nil)
                self.progressBanners.closeAll()
                self.setReceiverStatus("Receiver stopped (%d)", "Odbiornik zatrzymany (%d)", proc.terminationStatus)
                self.statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: L10n.text("Error", "Błąd"))
                if !self.reportedFatalError {
                    self.showError(L10n.text("The receiver stopped", "Odbiornik zatrzymał się"), L10n.text("Restart the application to try again.", "Uruchom aplikację ponownie, aby spróbować jeszcze raz."))
                }
            }
        }
        worker = process
        try process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: 0..<newline)
            buffer.removeSubrange(0...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let received = ProcessInfo.processInfo.systemUptime
            let emitted = (event["emitted_at"] as? NSNumber)?.doubleValue
            let deliveryMS = emitted.map { (Date().timeIntervalSince1970 - $0) * 1000 }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                let kind = event["event"] as? String ?? "unknown"
                let timed = ["incoming", "accepted", "receiving", "downloaded", "saving", "complete"].contains(kind)
                // IDs are generated locally; omit sender names, filenames and thumbnails.
                let id = (event["id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } ?? "none"
                if timed {
                    let pipe = deliveryMS.map { String(format: "%.1f", $0) } ?? "unknown"
                    self.log("UI event=\(kind) transfer=\(id) ipc_ms=\(pipe) queue_ms=\(String(format: "%.1f", (start - received) * 1000))")
                }
                self.receive(event)
                if timed {
                    self.log("UI handled event=\(kind) transfer=\(id) ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - start) * 1000))")
                }
            }
        }
    }

    private func log(_ message: String) {
        let date = Date()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let line = "\(self.logFormatter.string(from: date)) INFO \(message)\n"
            if let data = line.data(using: .utf8) { try? self.logHandle?.write(contentsOf: data) }
        }
    }

    @discardableResult private func send(_ message: [String: Any]) -> Bool {
        #if AIRFOLDER_CHECKS
        if let commandForChecks = commandForChecks {
            let accepted = commandForChecks(message)
            if accepted, automaticHoldsForChecks, message["command"] as? String == "hold_transfer" {
                DispatchQueue.main.async { [weak self] in
                    self?.receive(["event": "hold_result", "id": message["id"]!, "request_id": message["request_id"]!,
                                   "ok": true, "token": UUID().uuidString.lowercased()])
                }
            }
            return accepted
        }
        #endif
        guard let input = input, worker?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0a)
        do { try input.write(contentsOf: data); return true }
        catch { log("Could not deliver UI command"); return false }
    }

    private func receive(_ event: [String: Any]) {
        defer { refreshPendingMenu(); updateRestart.advance() }
        if ["update_status", "shutdown_complete"].contains(event["event"] as? String ?? "") {
            updateRestart.receive(event); return
        }
        if let id = event["id"] as? String, completedTransfers.contains(id),
           event["event"] as? String != "hold_result" {
            return
        }
        switch event["event"] as? String {
        case "pairing_pin":
            if let code = event["code"] as? String, let expiresAt = event["expires_at"] as? TimeInterval {
                pairingWindow.show(code: code, expiresAt: Date(timeIntervalSince1970: expiresAt))
            }
        case "pairing_closed":
            pairingWindow.close()
        case "discovery_status":
            guard let status = event["status"] as? String,
                  ["advertising", "waiting", "retrying"].contains(status) else { return }
            discoveryStatus = status
            refreshStatusLine()
        case "ready":
            workerReady = true
            #if AIMDROP_UPDATE_EXPERIMENT
            if let config = Bundle.main.object(forInfoDictionaryKey: "AimDropUpdateExperiment") as? [String: String] {
                let report = "build=\(config["build"]!) login=\(LoginItemManager.system.status().rawValue) path=\(Bundle.main.bundlePath)"
                try? Data(report.utf8).write(to: supportDirectory.appendingPathComponent("ready-" + config["build"]!), options: .atomic)
            }
            #endif
            appliedReceiverName = event["name"] as? String
            appliedAvatarDigest = event["avatar_digest"] as? String
            refreshReceiverName()
            setReceiverStatus("Ready to receive", "Gotowy do odbioru")
            synchronizeLanguage()
            synchronizeRetention()
            if appliedReceiverName != receiverName || appliedAvatarDigest != (try? selectedAvatar(preferences).digest) { synchronizeReceiverProfile() }
            presentNextPending()
        case "hold_result":
            guard let request = event["request_id"] as? String else { return }
            let waiting = holdRequests.removeValue(forKey: request)
            if choosingRequest == request { choosingRequest = nil }
            guard let waiting, pendingTransfers[waiting.id] != nil, !completedTransfers.contains(waiting.id) else {
                if let id = event["id"] as? String, let token = event["token"] as? String {
                    send(["command": "release_transfer", "id": id, "token": token])
                }
                return
            }
            guard event["ok"] as? Bool == true, let token = event["token"] as? String else {
                saveCouldNotStart(id: waiting.id)
                showError("AimDrop", L10n.text("This transfer is no longer available or is busy.", "Ten transfer jest już niedostępny lub jest w trakcie operacji."))
                return
            }
            heldTransfers[waiting.id] = token
            switch waiting.action {
            case .save:
                if panel == nil && trashAlert == nil && errorAlert == nil && settingsWindow?.isChoosingFile != true {
                    presentFolder(pendingTransfers[waiting.id]!)
                } else {
                    releaseTransfer(waiting.id)
                    promptedTransfers.remove(waiting.id)
                }
            case .trash: presentTrashConfirmation(id: waiting.id)
            case .automatic(let destination): beginAutomaticSave(id: waiting.id, destination: destination)
            }
        case "retention_result":
            guard event["request_id"] as? String == retentionRequestID else { return }
            retentionRequestID = nil
            if event["ok"] as? Bool != true {
                setSettingsStatus(event["message"] as? String ?? L10n.text("Could not update inbox settings.", "Nie udało się zmienić ustawień bufora."), error: true)
            }
        case "language_result":
            guard event["request_id"] as? String == languageRequestID else { return }
            languageRequestID = nil
            if event["ok"] as? Bool != true { setSettingsStatus(L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."), error: true) }
        case "trashing":
            if let id = event["id"] as? String { trashingTransfers.insert(id) }
        case "trashed":
            if let id = event["id"] as? String {
                completedTransfers.insert(id)
                removePending(id)
                notifications.cancel(id: id)
                progressBanners.remove(id: id)
            }
        case "trash_canceled":
            if let id = event["id"] as? String { trashingTransfers.remove(id) }
        case "trash_many_result":
            if let request = event["request_id"] as? String { bulkTrashRequests.removeValue(forKey: request) }
        case "profile_result":
            guard workerReady, let request = event["request_id"] as? String,
                  let pending = pendingProfileRequest, request == pending.id else { return }
            pendingProfileRequest = nil
            if event["ok"] as? Bool == true, event["name"] as? String == pending.name,
               event["avatar_digest"] as? String == pending.digest {
                appliedReceiverName = pending.name
                appliedAvatarDigest = pending.digest
                refreshReceiverName()
                setSettingsStatus(event["pairing_reset"] as? Bool == true
                    ? L10n.text("Select the receiver on the sending device, enter the PIN and reopen AirDrop.", "Wybierz odbiorcę na urządzeniu wysyłającym, wpisz PIN i otwórz ponownie AirDrop.")
                    : L10n.text("Settings saved.", "Ustawienia zapisane."))
            } else {
                setSettingsStatus(L10n.text("Settings were saved locally, but the receiver did not accept them. ", "Ustawienia zapisane lokalnie, ale odbiornik ich nie przyjął. ") + (event["message"] as? String ?? ""), error: true)
            }
        case "incoming":
            progressBanners.incoming(event)
            setReceiverStatus("Preparing to receive…", "Przygotowywanie odbioru…")
        case "pending":
            for transfer in event["transfers"] as? [[String: Any]] ?? [] {
                registerPending(transfer, automatic: false)
            }
            if event["initial"] as? Bool == true {
                inboxLoaded = true
                notifications.reconcilePending(ids: Set(pendingTransfers.keys))
                if let id = requestedSaveID, pendingTransfers[id] == nil {
                    requestedSaveID = nil
                    notifications.cancel(id: id)
                }
            }
            if let id = requestedSaveID, pendingTransfers[id] != nil { requestSave(id: id) }
        case "downloaded":
            guard let id = event["id"] as? String, !completedTransfers.contains(id),
                  handledDownloads.insert(id).inserted else { return }
            let routeNewDownload = !manuallyHandledTransfers.contains(id)
                && currentOffer != id && !savingTransfers.contains(id)
            registerPending(event, automatic: routeNewDownload)
            guard routeNewDownload else {
                if !savingTransfers.contains(id) { progressBanners.finish(id: id) }
                return
            }
            if !updateRestart.active, preferences.automaticSave, let destination = preferences.destination {
                progressBanners.finish(id: id, awaitingDestination: false)
                saveAutomatically(id: id, destination: destination)
            } else {
                progressBanners.finish(id: id)
                setReceiverStatus("Files received — choose a folder", "Pliki odebrane — wybierz folder")
                presentNextPending()
            }
        case "offer_closed":
            if let id = event["id"] as? String {
                notifications.cancel(id: id)
                progressBanners.remove(id: id)
            }
            if event["id"] as? String == currentOffer {
                panel?.cancel(nil)
            }
            setReceiverStatus("Ready to receive", "Gotowy do odbioru")
        case "accepted":
            setReceiverStatus("Waiting for files…", "Oczekiwanie na pliki…")
        case "receiving":
            if let id = event["id"] as? String {
                progressBanners.begin(id: id, progress: TransferProgress(event: event))
            }
            setReceiverStatus("Starting transfer…", "Rozpoczynanie odbioru…")
        case "progress":
            let progress = TransferProgress(event: event)
            statusIsReady = false
            statusText = { progress.text.replacingOccurrences(of: "\n", with: " · ") }
            refreshStatusLine()
            if let id = event["id"] as? String { progressBanners.update(id: id, progress: progress) }
        case "saving":
            setReceiverStatus("Saving received files…", "Zapisywanie odebranych plików…")
            if let id = event["id"] as? String {
                savingTransfers.insert(id)
                progressBanners.begin(id: id, progress: TransferProgress(event: event), receipt: pendingTransfers[id])
            }
        case "save_progress":
            let progress = TransferProgress(event: event)
            statusIsReady = false
            statusText = { progress.text.replacingOccurrences(of: "\n", with: " · ") }
            refreshStatusLine()
            if let id = event["id"] as? String { progressBanners.update(id: id, progress: progress) }
        case "complete":
            guard let id = event["id"] as? String, completedTransfers.insert(id).inserted else { return }
            removePending(id)
            if let path = event["directory"] as? String {
                lastFolder = URL(fileURLWithPath: path)
                UserDefaults.standard.set(path, forKey: "LastDirectory")
            }
            let count = event["count"] as? Int ?? 0
            setReceiverStatus("Received files: %d", "Odebrano pliki: %d", count)
            statusItem.button?.toolTip = L10n.format("AimDrop — received %d files", "AimDrop — odebrano %d plików", count)
            if let path = event["directory"] as? String {
                notifications.cancel(id: id)
                progressBanners.completed(id: id, target: TransferFileTarget(paths: event["paths"] as? [String] ?? [], directory: path), count: count)
                if preferences.completionSound { NSSound(named: "Glass")?.play() }
            }
        case "error":
            if event["phase"] as? String == "trashing", let id = event["id"] as? String {
                trashingTransfers.remove(id)
                releaseTransfer(id)
                let first = trashFailures.insert(id).inserted
                if event["automatic"] as? Bool != true || first {
                    showError("AimDrop", event["message"] as? String ?? L10n.text("Could not move the transfer to Trash. The files remain in the inbox.", "Nie udało się przenieść transferu do Kosza. Pliki pozostają w buforze."))
                }
                return
            }
            if let id = event["id"] as? String {
                releaseTransfer(id)
                progressBanners.remove(id: id)
                savingTransfers.remove(id)
                if event["phase"] as? String == "saving", let transfer = pendingTransfers[id] {
                    notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
                } else {
                    notifications.cancel(id: id)
                }
            }
            if event["fatal"] as? Bool == true { reportedFatalError = true }
            if event["phase"] as? String == "saving" { setReceiverStatus("Save failed — files are in the inbox", "Błąd zapisu — pliki są w buforze") }
            else { setReceiverStatus("Transfer failed", "Błąd odbioru") }
            showError("AimDrop", event["message"] as? String ?? L10n.text("The transfer failed.", "Transfer nie powiódł się."))
        case "canceled":
            if let id = event["id"] as? String {
                progressBanners.remove(id: id)
                notifications.cancel(id: id)
            }
            setReceiverStatus("Transfer canceled", "Odbieranie anulowane")
        case "save_canceled":
            if let id = event["id"] as? String {
                releaseTransfer(id)
                progressBanners.remove(id: id)
                savingTransfers.remove(id)
                if let transfer = pendingTransfers[id] {
                    notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
                }
            }
            setReceiverStatus("Save canceled — files are in the inbox", "Zapis anulowany — pliki są w buforze")
        default:
            break
        }
    }

    private func registerPending(_ event: [String: Any], automatic: Bool) {
        guard let id = event["id"] as? String, !completedTransfers.contains(id) else { return }
        if pendingTransfers[id] == nil {
            pendingOrder.append(id)
            if !automatic { promptedTransfers.insert(id) }
        }
        pendingTransfers[id] = event
        if automatic && currentOffer != id && !savingTransfers.contains(id) { promptedTransfers.remove(id) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === updateItem { return true }
        if menuItem.action == #selector(showSettings) { return !updateRestart.active }
        if menuItem.action == #selector(openLastFolder) {
            return lastFolder != nil || UserDefaults.standard.string(forKey: "LastDirectory") != nil
        }
        return true
    }

    private func canHandleTransfer(_ id: String) -> Bool {
        !updateRestart.active && workerReady && pendingTransfers[id] != nil && !completedTransfers.contains(id)
            && !savingTransfers.contains(id) && !trashingTransfers.contains(id) && heldTransfers[id] == nil
            && !bulkTrashRequests.values.contains(where: { $0.contains(id) })
            && panel == nil && trashAlert == nil && choosingRequest == nil
            && settingsWindow?.isChoosingFile != true && errorAlert == nil
    }
    private func refreshPendingMenu() {
        let requested = bulkTrashRequests.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        pendingMenu.update(Array(pendingTransfers.values), saving: savingTransfers,
                           trashing: trashingTransfers.union(requested), automaticTrash: preferences.automaticTrash)
    }
    private func removePending(_ id: String) {
        releaseTransfer(id)
        savingTransfers.remove(id); trashingTransfers.remove(id); trashFailures.remove(id)
        pendingTransfers.removeValue(forKey: id)
        pendingOrder.removeAll { $0 == id }
        promptedTransfers.remove(id)
        if requestedSaveID == id { requestedSaveID = nil }
    }
    private func releaseTransfer(_ id: String) {
        if let token = heldTransfers.removeValue(forKey: id) {
            send(["command": "release_transfer", "id": id, "token": token])
        }
    }
    private func holdTransfer(_ id: String, action: HoldAction, choosing: Bool) {
        let request = UUID().uuidString.lowercased()
        holdRequests[request] = (id, action)
        if choosing { choosingRequest = request }
        guard send(["command": "hold_transfer", "id": id, "request_id": request]) else {
            holdRequests.removeValue(forKey: request)
            if choosingRequest == request { choosingRequest = nil }
            saveCouldNotStart(id: id)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.holdRequests.removeValue(forKey: request) != nil else { return }
            self.send(["command": "release_transfer", "id": id, "token": request])
            if self.choosingRequest == request { self.choosingRequest = nil }
            self.saveCouldNotStart(id: id)
            self.showError("AimDrop", L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."))
        }
    }
    private func requestTrash(id: String) {
        guard canHandleTransfer(id) else { return }
        manuallyHandledTransfers.insert(id)
        holdTransfer(id, action: .trash, choosing: true)
    }
    private func requestTrashAll(ids displayedIDs: [String]? = nil) {
        let ids = (displayedIDs ?? pendingOrder).filter { canHandleTransfer($0) }
        guard !ids.isEmpty else { return }
        manuallyHandledTransfers.formUnion(ids)
        trashAllOfferIDs = ids
        presentTrashConfirmation(id: nil)
    }
    private func presentTrashConfirmation(id: String?) {
        guard panel == nil, errorAlert == nil, trashAlert == nil, !updateRestart.active,
              settingsWindow?.isChoosingFile != true else {
            if let id { releaseTransfer(id) }
            else { trashAllOfferIDs.removeAll() }
            return
        }
        pendingMenu.hidePreview()
        let bulk = id == nil
        let alert = NSAlert()
        alert.messageText = bulk ? L10n.text("Delete all unsaved transfers?", "Usunąć wszystkie niezapisane transfery?")
            : L10n.text("Delete this transfer?", "Usunąć ten transfer?")
        alert.informativeText = bulk
            ? L10n.format("Transfers to delete: %ld", "Transfery do usunięcia: %ld", trashAllOfferIDs.count) + "\n\n"
                + L10n.text("These files will be moved to Trash. Transfers being saved and new arrivals are excluded.", "Te pliki zostaną przeniesione do Kosza. Trwające zapisy i nowe przesyłki zostaną pominięte.")
            : L10n.text("All files in this transfer will be moved to Trash.", "Wszystkie pliki z tego transferu zostaną przeniesione do Kosza.")
        let cancel = alert.addButton(withTitle: L10n.text("Cancel", "Anuluj"))
        cancel.keyEquivalent = "\u{1b}"; cancel.target = self; cancel.action = #selector(cancelTrash)
        let remove = alert.addButton(withTitle: bulk ? L10n.text("Delete All", "Usuń wszystkie") : L10n.text("Delete", "Usuń"))
        remove.keyEquivalent = ""; remove.target = self; remove.action = #selector(confirmTrash)
        trashAlert = alert; trashOfferID = id
        alert.layout(); WindowPlacement.center(alert.window)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }
    @objc private func cancelTrash() { finishTrashConfirmation(delete: false) }
    @objc private func confirmTrash() { finishTrashConfirmation(delete: true) }
    private func finishTrashConfirmation(delete: Bool) {
        let id = trashOfferID
        let allIDs = trashAllOfferIDs
        trashAlert?.window.close(); trashAlert = nil; trashOfferID = nil
        trashAllOfferIDs.removeAll()
        if let id {
            if delete, let token = heldTransfers[id] {
                trashingTransfers.insert(id)
                if send(["command": "trash", "id": id, "token": token]) {
                    heldTransfers.removeValue(forKey: id)
                } else {
                    trashingTransfers.remove(id)
                    releaseTransfer(id)
                }
            } else { releaseTransfer(id) }
        } else if delete {
            let ids = allIDs.filter { canHandleTransfer($0) }
            for offset in stride(from: 0, to: ids.count, by: 512) {
                let batch = Array(ids[offset..<min(offset + 512, ids.count)])
                let request = UUID().uuidString.lowercased()
                bulkTrashRequests[request] = Set(batch)
                guard send(["command": "trash_many", "request_id": request, "ids": batch]) else {
                    bulkTrashRequests.removeValue(forKey: request)
                    showError("AimDrop", L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."))
                    break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, !self.quitting, self.bulkTrashRequests.removeValue(forKey: request) != nil else { return }
                    self.refreshPendingMenu()
                    self.showError("AimDrop", L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."))
                }
            }
        }
        refreshPendingMenu()
        presentNextPending()
    }

    private func requestSave(id: String) {
        guard !updateRestart.active else { return }
        guard !completedTransfers.contains(id), !savingTransfers.contains(id), !trashingTransfers.contains(id) else { return }
        manuallyHandledTransfers.insert(id)
        if currentOffer == id, let panel = panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard pendingTransfers[id] != nil else {
            if inboxLoaded {
                notifications.cancel(id: id)
                showError("AimDrop", L10n.text("This transfer is no longer available or is busy.", "Ten transfer jest już niedostępny lub jest w trakcie operacji."))
            } else { requestedSaveID = id }
            return
        }
        requestedSaveID = nil
        promptedTransfers.remove(id)
        pendingOrder.removeAll { $0 == id }
        pendingOrder.insert(id, at: 0)
        presentNextPending()
    }

    private func presentNextPending() {
        updateRestart.advance()
        guard panel == nil, trashAlert == nil, choosingRequest == nil, settingsWindow?.isChoosingFile != true, errorAlert == nil else { return }
        if let (title, message) = deferredError {
            deferredError = nil
            showError(title, message)
            return
        }
        guard !updateRestart.active, workerReady,
              let id = pendingOrder.first(where: { !promptedTransfers.contains($0) && !savingTransfers.contains($0) && !trashingTransfers.contains($0) && pendingTransfers[$0] != nil }),
              let event = pendingTransfers[id] else { return }
        promptedTransfers.insert(id)
        chooseFolder(event)
    }

    private func chooseFolder(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return }
        guard panel == nil, choosingRequest == nil else { return }
        holdTransfer(id, action: .save, choosing: true)
    }

    private func presentFolder(_ event: [String: Any]) {
        guard let id = event["id"] as? String, panel == nil else { return }
        manuallyHandledTransfers.insert(id)
        let picker = NSOpenPanel()
        picker.title = L10n.text("AimDrop — save received files", "AimDrop — zapisz odebrane pliki")
        let files = event["files"] as? [String] ?? []
        let preview = files.prefix(4).joined(separator: ", ")
        let suffix = files.count > 4 ? L10n.format(" and %d more", " i %d kolejnych", files.count - 4) : ""
        picker.message = L10n.format("Received: %@%@\nChoose a destination folder. Canceling keeps the files in the app's inbox.", "Odebrano: %@%@\nWybierz folder docelowy. Anulowanie zachowa pliki w buforze aplikacji.", preview, suffix)
        picker.prompt = L10n.text("Save here", "Zapisz tutaj")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        if let saved = UserDefaults.standard.string(forKey: "LastDirectory") {
            picker.directoryURL = URL(fileURLWithPath: saved)
        }
        currentOffer = id
        panel = picker
        refreshPendingMenu()
        setReceiverStatus("Choose a folder for received files…", "Wybierz folder dla odebranych plików…")
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = picker.url {
                UserDefaults.standard.set(url.path, forKey: "LastDirectory")
                self.startSave(id: id, directory: url.path)
            } else {
                self.pendingOrder.removeAll { $0 == id }
                self.pendingOrder.append(id)
                self.releaseTransfer(id)
                self.send(["command": "defer", "id": id])
                self.notifications.awaitingDestination(id: id, count: event["count"] as? Int ?? 0)
                self.setReceiverStatus("Received files are waiting to be saved", "Odebrane pliki czekają na zapis")
            }
            self.panel = nil
            self.currentOffer = nil
            self.refreshPendingMenu()
            DispatchQueue.main.async { self.presentNextPending() }
        }
    }

    private func showError(_ title: String, _ message: String) {
        if panel != nil || trashAlert != nil || settingsWindow?.isChoosingFile == true {
            deferredError = (title, message)
            return
        }
        errorAlert?.window.close()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let button = alert.addButton(withTitle: "OK")
        button.target = self
        button.action = #selector(closeError)
        errorAlert = alert
        alert.layout()
        WindowPlacement.center(alert.window)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func closeError() {
        errorAlert?.window.close()
        errorAlert = nil
        refreshPendingMenu()
        presentNextPending()
    }

    @objc private func openLastFolder() {
        if let folder = lastFolder ?? UserDefaults.standard.string(forKey: "LastDirectory").map({ URL(fileURLWithPath: $0) }) {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func showSettings() {
        guard !updateRestart.active else { return }
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onSave = { [weak self] value in self?.applyPreferences(value) ?? false }
            controller.canChooseFile = { [weak self] in self?.panel == nil && self?.trashAlert == nil && self?.choosingRequest == nil && self?.errorAlert == nil && self?.updateRestart.active == false }
            controller.onPickerClosed = { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.presentNextPending() }
            }
            settingsWindow = controller
        }
        settingsWindow?.present(preferences: preferences, status: settingsStatus)
        if let destination = preferences.destination {
            destinationQueue.async { [weak self] in
                guard let resolved = try? destination.resolve() else { return }
                DispatchQueue.main.async { self?.refreshSavedDestination(from: destination, to: resolved.refreshed) }
            }
        }
    }

    @discardableResult private func applyPreferences(_ value: AppPreferences) -> Bool {
        do {
            let retentionChanged = preferences.retentionDays != value.retentionDays || preferences.automaticTrash != value.automaticTrash
            let avatar = try selectedAvatar(value)
            _ = try materializeAvatar(value, avatar: avatar)
            preferences = try preferenceStore.save(value)
            notifications.setUpdateNotificationsEnabled(preferences.updateNotifications)
            L10n.configure(preferences.language)
            refreshLanguage()
            synchronizeReceiverProfile()
            refreshPendingMenu()
            if retentionChanged { synchronizeRetention() }
            return true
        } catch { setSettingsStatus(error.localizedDescription, error: true); return false }
    }

    private func synchronizeRetention() {
        guard workerReady else { return }
        let request = UUID().uuidString.lowercased()
        retentionRequestID = request
        if !send(["command": "set_retention", "request_id": request,
                  "days": preferences.retentionDays, "enabled": preferences.automaticTrash]) {
            retentionRequestID = nil
            setSettingsStatus(L10n.text("Could not update inbox settings.", "Nie udało się zmienić ustawień bufora."), error: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.retentionRequestID == request else { return }
            self.retentionRequestID = nil
            self.setSettingsStatus(L10n.text("Could not update inbox settings.", "Nie udało się zmienić ustawień bufora."), error: true)
        }
    }

    private func synchronizeLanguage() {
        let request = UUID().uuidString.lowercased()
        languageRequestID = request
        if !send(["command": "set_language", "language": L10n.languageCode, "request_id": request]) {
            languageRequestID = nil
            setSettingsStatus(L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."), error: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.languageRequestID == request else { return }
            self.languageRequestID = nil
            self.setSettingsStatus(L10n.text("The receiver did not respond. Try again.", "Odbiornik nie odpowiedział. Spróbuj ponownie."), error: true)
        }
    }

    private func selectedAvatar(_ value: AppPreferences) throws -> ReceiverAvatar {
        if let data = value.avatarPNG { return try ReceiverAvatar(png: data) }
        guard let url = Bundle.main.url(forResource: "AimDropAvatar", withExtension: "png") else { throw AvatarError.missingDefault }
        return try ReceiverAvatar.defaultLogo(at: url)
    }
    private func materializeAvatar(_ value: AppPreferences, avatar: ReceiverAvatar) throws -> String? {
        guard value.avatarPNG != nil else { return nil }
        return try avatar.materialize(in: supportDirectory.appendingPathComponent("Avatars", isDirectory: true)).path
    }
    private func synchronizeReceiverProfile() {
        guard workerReady else {
            setSettingsStatus(L10n.text("Saved. Settings will be used the next time the receiver starts.", "Zapisano. Ustawienia zostaną użyte przy następnym uruchomieniu."))
            return
        }
        do {
            let avatar = try selectedAvatar(preferences)
            if pendingProfileRequest?.name == receiverName && pendingProfileRequest?.digest == avatar.digest { return }
            if appliedReceiverName == receiverName && appliedAvatarDigest == avatar.digest && pendingProfileRequest == nil {
                setSettingsStatus(L10n.text("Settings saved.", "Ustawienia zapisane.")); return
            }
            let path = try materializeAvatar(preferences, avatar: avatar)
            let request = UUID().uuidString
            pendingProfileRequest = (request, receiverName, avatar.digest)
            guard send(["command": "set_profile", "request_id": request, "name": receiverName,
                        "avatar_path": path as Any? ?? NSNull(), "avatar_digest": avatar.digest]) else {
                pendingProfileRequest = nil
                setSettingsStatus(L10n.text("Saved locally. The receiver connection is unavailable.", "Zapisano lokalnie. Połączenie z odbiornikiem jest niedostępne."), error: true); return
            }
            setSettingsStatus(L10n.text("Saved. Updating the receiver…", "Zapisano. Trwa aktualizowanie odbiornika…"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.pendingProfileRequest?.id == request else { return }
                self.pendingProfileRequest = nil
                self.setSettingsStatus(L10n.text("Saved locally. The receiver has not confirmed the settings yet.", "Zapisano lokalnie. Odbiornik jeszcze nie potwierdził ustawień."), error: true)
            }
        } catch { setSettingsStatus(error.localizedDescription, error: true) }
    }

    private func setSettingsStatus(_ text: String, error: Bool = false) {
        if error && updateRestart.active { updateSettingsFailed = true }
        settingsStatus = text
        settingsWindow?.setSavedStatus(text, error: error)
    }

    private func refreshReceiverName() {
        let name = appliedReceiverName ?? receiverName
        nameLine.title = name.count > 40 ? String(name.prefix(39)) + "…" : name
        nameLine.toolTip = L10n.format("AirDrop receiver name: %@", "Nazwa odbiorcy w AirDrop: %@", name)
    }

    private func saveAutomatically(id: String, destination: SaveDestination) {
        promptedTransfers.insert(id)
        savingTransfers.insert(id)
        holdTransfer(id, action: .automatic(destination), choosing: false)
    }

    private func beginAutomaticSave(id: String, destination: SaveDestination) {
        setReceiverStatus("Preparing automatic save…", "Przygotowywanie automatycznego zapisu…")
        destinationQueue.async { [weak self] in
            let result = Result { try destination.resolve() }
            DispatchQueue.main.async {
                guard let self = self, !self.quitting, self.pendingTransfers[id] != nil,
                      self.savingTransfers.contains(id) else { return }
                switch result {
                case .success(let resolved):
                    self.refreshSavedDestination(from: destination, to: resolved.refreshed)
                    self.startSave(id: id, directory: resolved.url.path)
                case .failure:
                    self.saveCouldNotStart(id: id)
                    self.showError(L10n.text("Save folder unavailable", "Folder zapisu jest niedostępny"), L10n.text("Your files are waiting in the inbox. Connect the drive or choose another folder from Unsaved transfers.", "Odebrane pliki czekają na zapis. Podłącz dysk lub wybierz inny folder z menu Niezapisane transfery."))
                }
            }
        }
    }

    private func startSave(id: String, directory: String) {
        guard pendingTransfers[id] != nil, !completedTransfers.contains(id) else { return }
        promptedTransfers.insert(id)
        savingTransfers.insert(id)
        refreshPendingMenu()
        var command: [String: Any] = ["command": "save", "id": id, "directory": directory]
        if let token = heldTransfers[id] { command["token"] = token }
        if send(command) { heldTransfers.removeValue(forKey: id) }
        else { saveCouldNotStart(id: id) }
    }

    private func refreshSavedDestination(from old: SaveDestination, to updated: SaveDestination) {
        guard preferences.destination == old, updated != old else { return }
        var value = preferences
        value.destination = updated
        do {
            preferences = try preferenceStore.save(value)
            settingsWindow?.refreshDestination(from: old, to: updated)
        } catch { log("Could not refresh the saved destination bookmark") }
    }

    private func saveCouldNotStart(id: String) {
        releaseTransfer(id)
        savingTransfers.remove(id)
        progressBanners.remove(id: id)
        if let transfer = pendingTransfers[id] {
            notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
        }
        setReceiverStatus("Files are waiting to be saved", "Pliki czekają na zapis")
        refreshPendingMenu()
    }

    @objc private func showAbout() {
        let screen = WindowPlacement.activeScreen()
        NSApp.activate(ignoringOtherApps: true)
        if let aboutWindow {
            WindowPlacement.center(aboutWindow, on: screen)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var presented: NSWindow?
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                              object: nil, queue: .main) { notification in
            presented = notification.object as? NSWindow
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NSApp.orderFrontStandardAboutPanel(nil)
        // Keep the actual standard panel; never assume that a previous key
        // window is the About panel when activation is asynchronous.
        aboutWindow = NSApp.windows.first { !existingWindows.contains(ObjectIdentifier($0)) } ?? presented
        if let aboutWindow { WindowPlacement.center(aboutWindow, on: screen) }
    }

    @objc private func checkForUpdates() {
        sparkleUpdater.checkManually()
    }

    private func configureUpdates() {
        sparkleUpdater.log = { [weak self] in self?.log($0) }
        sparkleUpdater.onManualCheck = { [weak self] in self?.updater.manualCheckStarted() }
        sparkleUpdater.onPresented = { [weak self] in self?.updater.markNotified($0) }
        sparkleUpdater.canCancelPreparation = { [weak self] in self?.updateRestart.canCancel ?? true }
        sparkleUpdater.prepareRestart = { [weak self] completion in
            guard let self, self.workerReady else { completion(false); return }
            self.settingsResolvedForUpdate = false; self.resolvingUpdateSettings = false; self.updateSettingsFailed = false
            self.updateRestart.begin(completion)
            // An unconfirmed delete is not an already-started Trash operation.
            // Close admission first: dismissing the alert normally presents
            // the next pending picker, which must not start during preparation.
            if self.updateRestart.active, self.trashAlert != nil { self.finishTrashConfirmation(delete: false) }
        }
        sparkleUpdater.cancelPreparation = { [weak self] in
            guard let self else { return }
            let restartWorker = self.updateRestart.phase == .ready
            self.updateRestart.resetAfterInstallerFailure()
            self.settingsWindow?.cancelUpdatePreparation()
            self.resolvingUpdateSettings = false; self.settingsResolvedForUpdate = false
            if restartWorker {
                self.inboxLoaded = false
                do { try self.startWorker() } catch { self.showError("AimDrop", error.localizedDescription) }
            }
            self.presentNextPending()
        }
        updateRestart.send = { [weak self] in self?.send($0) ?? false }
        updateRestart.uiReady = { [weak self] in self?.updateUIReady() ?? false }
        updateRestart.onChange = { [weak self] in
            guard let self else { return }
            self.refreshPendingMenu()
            if self.updateRestart.phase == .stopping {
                self.sparkleUpdater.showWorking(L10n.text("Restarting AimDrop…", "Ponowne uruchamianie AimDrop…"), cancellable: false)
            } else if self.updateRestart.phase == .waiting {
                self.sparkleUpdater.showWorking(L10n.text("Waiting for current operations…", "Oczekiwanie na zakończenie bieżących operacji…"))
            }
        }
        updateRestart.onFailure = { [weak self] in
            self?.showError("AimDrop", L10n.text("The receiver did not confirm a safe shutdown. The update was canceled.", "Odbiornik nie potwierdził bezpiecznego zakończenia pracy. Aktualizacja została anulowana."))
        }
    }

    private func updateUIReady() -> Bool {
        if updateSettingsFailed {
            DispatchQueue.main.async { [weak self] in self?.sparkleUpdater.cancel() }
            return false
        }
        guard panel == nil, trashAlert == nil, choosingRequest == nil, holdRequests.isEmpty,
              savingTransfers.isEmpty, trashingTransfers.isEmpty, bulkTrashRequests.isEmpty,
              settingsWindow?.isChoosingFile != true, errorAlert == nil, deferredError == nil else { return false }
        guard settingsResolvedForUpdate else {
            if !resolvingUpdateSettings {
                resolvingUpdateSettings = true
                let request = updateRestart.requestID
                if let settingsWindow {
                    settingsWindow.resolveForUpdate { [weak self] accepted in
                        guard let self, self.updateRestart.requestID == request, self.updateRestart.active else { return }
                        self.resolvingUpdateSettings = false
                        self.settingsResolvedForUpdate = accepted
                        if accepted { DispatchQueue.main.async { self.updateRestart.advance() } }
                        else { self.sparkleUpdater.cancel() }
                    }
                } else {
                    settingsResolvedForUpdate = true; resolvingUpdateSettings = false
                    DispatchQueue.main.async { [weak self] in self?.updateRestart.advance() }
                }
            }
            return false
        }
        return pendingProfileRequest == nil && retentionRequestID == nil && languageRequestID == nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Every quit path must pass this gate, including Sparkle's resumed
        // install path, which does not always call the postpone-relaunch hook.
        if updateRestart.active { return updateRestart.phase == .ready && sparkleUpdater.committed ? .terminateNow : .terminateCancel }
        if sparkleUpdater.installing { sparkleUpdater.showUpdateInFocus(); return .terminateCancel }
        return .terminateNow
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    #if AIMDROP_UPDATE_EXPERIMENT
    private var experimentTimer: Timer?
    private func startUpdateExperiment() {
        guard let config = Bundle.main.object(forInfoDictionaryKey: "AimDropUpdateExperiment") as? [String: String] else { return }
        log("Update experiment build=\(config["build"] ?? "?") login=\(LoginItemManager.system.status().rawValue) path=\(Bundle.main.bundlePath)")
        if config["install"] == "yes" {
            sparkleUpdater.onPresented = { [weak self] _ in
                DispatchQueue.main.async { self?.sparkleUpdater.installForExperiment() }
            }
        }
        experimentTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.workerReady else { return }
            if config["install"] == "yes", FileManager.default.fileExists(atPath: self.supportDirectory.appendingPathComponent("install").path) {
                self.experimentTimer?.invalidate()
                self.sparkleUpdater.checkManually()
            } else if config["install"] != "yes", FileManager.default.fileExists(atPath: self.supportDirectory.appendingPathComponent("cleanup").path) {
                self.experimentTimer?.invalidate()
                try? LoginItemManager.system.setEnabled(false)
                NSApp.terminate(nil)
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        updater.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        trashAlert?.window.close()
        pairingWindow.close()
        progressBanners.closeAll()
        pendingMenu.hidePreview()
        send(["command": "shutdown"])
        try? input?.close()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = worker, process.isRunning { process.terminate() }
        try? logHandle?.close()
    }

    #if AIRFOLDER_CHECKS
    // Exercise the actual event routing without a network worker or user dialogs.
    func prepareForChecks(defaults: UserDefaults, preferences: AppPreferences, storageDirectory: URL? = nil, reservePicker: Bool = true, automaticHolds: Bool = true, command: @escaping ([String: Any]) -> Bool) {
        preferenceStore = PreferencesStore(defaults: defaults)
        self.preferences = preferences
        L10n.configure(preferences.language)
        activeLanguageCode = L10n.languageCode
        appliedReceiverName = preferences.receiverName
        updater = UpdateChecker(defaults: defaults)
        appliedAvatarDigest = try? selectedAvatar(preferences).digest
        storageForChecks = storageDirectory
        workerReady = true
        commandForChecks = command
        automaticHoldsForChecks = automaticHolds
        setupMenu()
        if reservePicker { panel = NSOpenPanel() }  // Reserve without displaying.
    }
    func eventForChecks(_ event: [String: Any]) { receive(event) }
    func requestSaveForChecks(id: String) { requestSave(id: id) }
    @discardableResult func preferencesForChecks(_ preferences: AppPreferences) -> Bool { applyPreferences(preferences) }
    var pendingIDsForChecks: Set<String> { Set(pendingTransfers.keys) }
    var savingIDsForChecks: Set<String> { savingTransfers }
    var appliedNameForChecks: String? { appliedReceiverName }
    var appliedAvatarForChecks: String? { appliedAvatarDigest }
    var pendingMenuForChecks: NSMenuItem { pendingMenu.rebuild(); return pendingMenu.item }
    var statusForChecks: String { statusLine.title }
    func requestTrashForChecks(id: String) { requestTrash(id: id) }
    func requestTrashAllForChecks() { requestTrashAll() }
    var trashAlertForChecks: NSAlert? { trashAlert }
    func finishTrashForChecks(delete: Bool) { finishTrashConfirmation(delete: delete) }
    var currentFolderIDForChecks: String? { currentOffer }
    func cancelFolderForChecks() { panel?.cancel(nil) }
    func showSettingsForChecks() -> SettingsWindowController { showSettings(); return settingsWindow! }
    func prepareUpdateForChecks(_ completion: @escaping (Bool) -> Void) { configureUpdates(); sparkleUpdater.prepareRestart?(completion) }
    func updateWorkerExitedForChecks() { updateRestart.workerExited(success: true) }
    var updateItemForChecks: NSMenuItem { updateItem }
    func showAboutForChecks() -> NSWindow? { showAbout(); return aboutWindow }
    func closeForChecks() {
        pairingWindow.close()
        sparkleUpdater.cancelPreparation = nil
        sparkleUpdater.dismissUpdateInstallation()
        pendingMenu.hidePreview()
        progressBanners.closeAll()
        settingsWindow?.close()
        settingsWindow?.cancelUpdatePreparation()
        trashAlert?.window.close()
        aboutWindow?.close()
        panel?.cancel(nil); panel = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
    #endif
}
