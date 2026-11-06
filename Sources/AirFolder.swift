import Cocoa

// The receiver owns the network; AppKit owns the folder chooser on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Uruchamianie…", action: nil, keyEquivalent: "")
    private let nameLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let saveLatestItem = NSMenuItem(title: "Zapisz pliki…", action: nil, keyEquivalent: "")
    private var worker: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var logHandle: FileHandle?
    private var panel: NSOpenPanel?
    private var currentOffer: String?
    private var pendingTransfers: [String: [String: Any]] = [:]
    private var latestReceivedID: String?
    private var pendingOrder: [String] = []
    private var promptedTransfers = Set<String>()
    private var savingTransfers = Set<String>()
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
    private let pairingWindow = PairingWindowController()
    #if AIRFOLDER_CHECKS
    private var commandForChecks: (([String: Any]) -> Bool)?
    private var storageForChecks: URL?
    #endif

    private var supportDirectory: URL {
        #if AIRFOLDER_CHECKS
        if let storageForChecks { return storageForChecks }
        #endif
        // Stable storage identity: pending transfers survive the AirFolder rename.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirFrajer", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AirFolderArtwork.applicationIcon
        setupMenu()
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let logURL = supportDirectory.appendingPathComponent("receiver.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()
            notifications.log = { [weak self] message in self?.log(message) }
            progressBanners.log = { [weak self] message in self?.log(message) }
            notifications.start()
            notifications.onSavePending = { [weak self] id in self?.requestSave(id: id) }
            progressBanners.onCancel = { [weak self] id, saving in
                guard let self = self else { return }
                self.send(["command": saving ? "cancel_save" : "cancel_transfer", "id": id])
            }
            try startWorker()
        } catch {
            showError("Nie można uruchomić odbiornika", error.localizedDescription)
            statusLine.title = "Błąd uruchamiania"
        }
    }

    private func setupMenu() {
        setupApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AirFolderArtwork.menuBarIcon()
        statusItem.button?.toolTip = "AirFolder — odbierz AirDrop do wybranego folderu"
        let menu = NSMenu()
        refreshReceiverName()
        menu.addItem(nameLine)
        menu.addItem(statusLine)
        menu.addItem(.separator())
        saveLatestItem.target = self
        saveLatestItem.action = #selector(saveLatestFiles)
        saveLatestItem.isHidden = true
        menu.addItem(saveLatestItem)
        addItem("Pokaż ostatni folder", #selector(openLastFolder), to: menu)
        menu.addItem(.separator())
        let settings = addItem("Ustawienia…", #selector(showSettings), to: menu)
        settings.keyEquivalent = ","
        addItem("O AirFolder", #selector(showAbout), to: menu)
        menu.addItem(.separator())
        let quit = addItem("Zakończ AirFolder", #selector(quitApp), to: menu)
        quit.keyEquivalent = "q"
        statusItem.menu = menu
    }

    private func setupApplicationMenu() {
        // Accessory apps still need a responder-chain Edit menu for text shortcuts.
        let main = NSMenu()
        let application = NSMenuItem(title: "AirFolder", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "AirFolder")
        addItem("O AirFolder", #selector(showAbout), to: applicationMenu)
        addItem("Ustawienia…", #selector(showSettings), to: applicationMenu).keyEquivalent = ","
        applicationMenu.addItem(.separator())
        addItem("Zakończ AirFolder", #selector(quitApp), to: applicationMenu).keyEquivalent = "q"
        application.submenu = applicationMenu
        main.addItem(application)
        let edit = NSMenuItem(title: "Edycja", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edycja")
        for (title, action, key) in [("Cofnij", "undo:", "z"), ("Wytnij", "cut:", "x"),
                                      ("Kopiuj", "copy:", "c"), ("Wklej", "paste:", "v"),
                                      ("Zaznacz wszystko", "selectAll:", "a")] {
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
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "AirFolder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Brak zasobów aplikacji."])
        }
        let process = Process()
        let avatar = try selectedAvatar(preferences)
        let avatarPath = try materializeAvatar(preferences, avatar: avatar)
        let python = Bundle.main.object(forInfoDictionaryKey: "AFPythonExecutable") as? String ?? "/usr/bin/python3"
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", "-u", resources.appendingPathComponent("receiver/main.py").path,
                             "--name=\(receiverName)", "--state-dir", supportDirectory.path,
                             "--native-helper", resources.deletingLastPathComponent().appendingPathComponent("MacOS/AirFolderReceiver").path,
                             "--native-artwork", resources.appendingPathComponent("AirFolder.png").path,
                             "--avatar-digest", avatar.digest]
        if let avatarPath { process.arguments?.append(contentsOf: ["--native-avatar", avatarPath]) }
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
                self.workerReady = false
                self.pairingWindow.close()
                self.pendingProfileRequest = nil
                self.savingTransfers.removeAll()
                self.refreshLatestSaveItem()
                self.setSettingsStatus("Odbiornik jest zatrzymany. Ustawienia zostaną użyte przy następnym uruchomieniu.")
                self.panel?.cancel(nil)
                self.progressBanners.closeAll()
                self.statusLine.title = "Odbiornik zatrzymany (\(proc.terminationStatus))"
                self.statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Błąd")
                if !self.reportedFatalError {
                    self.showError("Odbiornik zatrzymał się", "Uruchom aplikację ponownie, aby spróbować jeszcze raz.")
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
        if let commandForChecks = commandForChecks { return commandForChecks(message) }
        #endif
        guard let input = input, worker?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0a)
        do { try input.write(contentsOf: data); return true }
        catch { log("Could not deliver UI command"); return false }
    }

    private func receive(_ event: [String: Any]) {
        defer { refreshLatestSaveItem() }
        if event.keys.contains("latest_received_id") {
            latestReceivedID = event["latest_received_id"] as? String
        }
        switch event["event"] as? String {
        case "pairing_pin":
            if let code = event["code"] as? String { pairingWindow.show(code: code) }
        case "pairing_closed":
            pairingWindow.close()
        case "ready":
            workerReady = true
            appliedReceiverName = event["name"] as? String
            appliedAvatarDigest = event["avatar_digest"] as? String
            refreshReceiverName()
            statusLine.title = "Gotowy do odbioru"
            if appliedReceiverName != receiverName || appliedAvatarDigest != (try? selectedAvatar(preferences).digest) { synchronizeReceiverProfile() }
            presentNextPending()
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
                    ? "Wybierz odbiorcę na iPhonie, wpisz PIN i otwórz ponownie AirDrop."
                    : "Ustawienia zapisane.")
            } else {
                setSettingsStatus("Ustawienia zapisane lokalnie, ale odbiornik ich nie przyjął. " + (event["message"] as? String ?? ""), error: true)
            }
        case "incoming":
            progressBanners.incoming(event)
            statusLine.title = "Przygotowywanie bufora odbioru…"
        case "pending":
            for transfer in event["transfers"] as? [[String: Any]] ?? [] {
                registerPending(transfer, automatic: false)
            }
            if let id = requestedSaveID, pendingTransfers[id] != nil { requestSave(id: id) }
        case "downloaded":
            guard let id = event["id"] as? String, !completedTransfers.contains(id),
                  handledDownloads.insert(id).inserted else { return }
            if !event.keys.contains("latest_received_id") { latestReceivedID = id }
            let routeNewDownload = !manuallyHandledTransfers.contains(id)
                && currentOffer != id && !savingTransfers.contains(id)
            registerPending(event, automatic: routeNewDownload)
            guard routeNewDownload else {
                if !savingTransfers.contains(id) { progressBanners.finish(id: id) }
                return
            }
            if preferences.automaticSave, let destination = preferences.destination {
                progressBanners.finish(id: id, awaitingDestination: false)
                saveAutomatically(id: id, destination: destination)
            } else {
                progressBanners.finish(id: id)
                statusLine.title = "Pliki odebrane — wybierz folder"
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
            statusLine.title = "Gotowy do odbioru"
        case "accepted":
            statusLine.title = "Oczekiwanie na pliki…"
        case "receiving":
            if let id = event["id"] as? String {
                progressBanners.begin(id: id, progress: TransferProgress(event: event))
            }
            statusLine.title = "Rozpoczynanie odbioru…"
        case "progress":
            let progress = TransferProgress(event: event)
            statusLine.title = progress.text.replacingOccurrences(of: "\n", with: " · ")
            if let id = event["id"] as? String { progressBanners.update(id: id, progress: progress) }
        case "saving":
            statusLine.title = "Zapisywanie odebranych plików…"
            if let id = event["id"] as? String {
                savingTransfers.insert(id)
                progressBanners.begin(id: id, progress: TransferProgress(event: event), receipt: pendingTransfers[id])
            }
        case "save_progress":
            let progress = TransferProgress(event: event)
            statusLine.title = progress.text.replacingOccurrences(of: "\n", with: " · ")
            if let id = event["id"] as? String { progressBanners.update(id: id, progress: progress) }
        case "complete":
            guard let id = event["id"] as? String, completedTransfers.insert(id).inserted else { return }
            savingTransfers.remove(id)
            pendingTransfers.removeValue(forKey: id)
            pendingOrder.removeAll { $0 == id }
            if let path = event["directory"] as? String {
                lastFolder = URL(fileURLWithPath: path)
                UserDefaults.standard.set(path, forKey: "LastDirectory")
            }
            let count = event["count"] as? Int ?? 0
            statusLine.title = "Odebrano pliki: \(count)"
            statusItem.button?.toolTip = "AirFolder — odebrano \(count) plików"
            if let path = event["directory"] as? String {
                notifications.cancel(id: id)
                progressBanners.completed(id: id, target: TransferFileTarget(paths: event["paths"] as? [String] ?? [], directory: path), count: count)
                if preferences.completionSound { NSSound(named: "Glass")?.play() }
            }
        case "error":
            if let id = event["id"] as? String {
                progressBanners.remove(id: id)
                savingTransfers.remove(id)
                if event["phase"] as? String == "saving", let transfer = pendingTransfers[id] {
                    notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
                } else {
                    notifications.cancel(id: id)
                }
            }
            if event["fatal"] as? Bool == true { reportedFatalError = true }
            statusLine.title = event["phase"] as? String == "saving" ? "Błąd zapisu — pliki są w buforze" : "Błąd odbioru"
            showError("AirFolder", event["message"] as? String ?? "Transfer nie powiódł się.")
        case "canceled":
            if let id = event["id"] as? String {
                progressBanners.remove(id: id)
                notifications.cancel(id: id)
            }
            statusLine.title = "Odbieranie anulowane"
        case "save_canceled":
            if let id = event["id"] as? String {
                progressBanners.remove(id: id)
                savingTransfers.remove(id)
                if let transfer = pendingTransfers[id] {
                    notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
                }
            }
            statusLine.title = "Zapis anulowany — pliki są w buforze"
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
        if menuItem === saveLatestItem {
            return latestSavableID != nil && workerReady && panel == nil
                && settingsWindow?.isChoosingFile != true && errorAlert == nil
        }
        if menuItem.action == #selector(openLastFolder) {
            return lastFolder != nil || UserDefaults.standard.string(forKey: "LastDirectory") != nil
        }
        return true
    }

    private var latestSavableID: String? {
        guard let id = latestReceivedID, pendingTransfers[id] != nil,
              promptedTransfers.contains(id), !completedTransfers.contains(id),
              !savingTransfers.contains(id), currentOffer != id else { return nil }
        return id
    }
    private func refreshLatestSaveItem() {
        saveLatestItem.isHidden = latestSavableID == nil
        saveLatestItem.isEnabled = validateMenuItem(saveLatestItem)
    }
    @objc private func saveLatestFiles() {
        guard validateMenuItem(saveLatestItem), let id = latestSavableID else { return }
        requestSave(id: id)
    }

    private func requestSave(id: String) {
        guard !completedTransfers.contains(id), !savingTransfers.contains(id) else { return }
        manuallyHandledTransfers.insert(id)
        if currentOffer == id, let panel = panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard pendingTransfers[id] != nil else { requestedSaveID = id; return }
        requestedSaveID = nil
        promptedTransfers.remove(id)
        pendingOrder.removeAll { $0 == id }
        pendingOrder.insert(id, at: 0)
        presentNextPending()
    }

    private func presentNextPending() {
        guard panel == nil, settingsWindow?.isChoosingFile != true, errorAlert == nil else { return }
        if let (title, message) = deferredError {
            deferredError = nil
            showError(title, message)
            return
        }
        guard workerReady,
              let id = pendingOrder.first(where: { !promptedTransfers.contains($0) && !savingTransfers.contains($0) && pendingTransfers[$0] != nil }),
              let event = pendingTransfers[id] else { return }
        promptedTransfers.insert(id)
        chooseFolder(event)
    }

    private func chooseFolder(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return }
        guard panel == nil else { return }
        manuallyHandledTransfers.insert(id)
        let picker = NSOpenPanel()
        picker.title = "AirFolder — zapisz odebrane pliki"
        let files = event["files"] as? [String] ?? []
        let preview = files.prefix(4).joined(separator: ", ")
        let suffix = files.count > 4 ? " i \(files.count - 4) kolejnych" : ""
        picker.message = "Odebrano: \(preview)\(suffix)\nWybierz folder docelowy. Anulowanie zachowa pliki w buforze aplikacji."
        picker.prompt = "Zapisz tutaj"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        if let saved = UserDefaults.standard.string(forKey: "LastDirectory") {
            picker.directoryURL = URL(fileURLWithPath: saved)
        }
        currentOffer = id
        panel = picker
        refreshLatestSaveItem()
        statusLine.title = "Wybierz folder dla odebranych plików…"
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = picker.url {
                UserDefaults.standard.set(url.path, forKey: "LastDirectory")
                self.startSave(id: id, directory: url.path)
            } else {
                self.pendingOrder.removeAll { $0 == id }
                self.pendingOrder.append(id)
                self.send(["command": "defer", "id": id])
                self.notifications.awaitingDestination(id: id, count: event["count"] as? Int ?? 0)
                self.statusLine.title = "Odebrane pliki czekają na zapis"
            }
            self.panel = nil
            self.currentOffer = nil
            self.refreshLatestSaveItem()
            DispatchQueue.main.async { self.presentNextPending() }
        }
    }

    private func showError(_ title: String, _ message: String) {
        if panel != nil || settingsWindow?.isChoosingFile == true {
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
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func closeError() {
        errorAlert?.window.close()
        errorAlert = nil
        refreshLatestSaveItem()
        presentNextPending()
    }

    @objc private func openLastFolder() {
        if let folder = lastFolder ?? UserDefaults.standard.string(forKey: "LastDirectory").map({ URL(fileURLWithPath: $0) }) {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onSave = { [weak self] value in self?.applyPreferences(value) ?? false }
            controller.canChooseFile = { [weak self] in self?.panel == nil && self?.errorAlert == nil }
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
            let avatar = try selectedAvatar(value)
            _ = try materializeAvatar(value, avatar: avatar)
            preferences = try preferenceStore.save(value)
            synchronizeReceiverProfile()
            return true
        } catch { setSettingsStatus(error.localizedDescription, error: true); return false }
    }

    private func selectedAvatar(_ value: AppPreferences) throws -> ReceiverAvatar {
        if let data = value.avatarPNG { return try ReceiverAvatar(png: data) }
        guard let url = Bundle.main.url(forResource: "AirFolder", withExtension: "png") else { throw AvatarError.missingDefault }
        return try ReceiverAvatar.defaultLogo(at: url)
    }
    private func materializeAvatar(_ value: AppPreferences, avatar: ReceiverAvatar) throws -> String? {
        guard value.avatarPNG != nil else { return nil }
        return try avatar.materialize(in: supportDirectory.appendingPathComponent("Avatars", isDirectory: true)).path
    }
    private func synchronizeReceiverProfile() {
        guard workerReady else {
            setSettingsStatus("Zapisano. Ustawienia zostaną użyte przy następnym uruchomieniu.")
            return
        }
        do {
            let avatar = try selectedAvatar(preferences)
            if pendingProfileRequest?.name == receiverName && pendingProfileRequest?.digest == avatar.digest { return }
            if appliedReceiverName == receiverName && appliedAvatarDigest == avatar.digest && pendingProfileRequest == nil {
                setSettingsStatus("Ustawienia zapisane."); return
            }
            let path = try materializeAvatar(preferences, avatar: avatar)
            let request = UUID().uuidString
            pendingProfileRequest = (request, receiverName, avatar.digest)
            guard send(["command": "set_profile", "request_id": request, "name": receiverName,
                        "avatar_path": path as Any? ?? NSNull(), "avatar_digest": avatar.digest]) else {
                pendingProfileRequest = nil
                setSettingsStatus("Zapisano lokalnie. Połączenie z odbiornikiem jest niedostępne."); return
            }
            setSettingsStatus("Zapisano. Trwa aktualizowanie odbiornika…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.pendingProfileRequest?.id == request else { return }
                self.setSettingsStatus("Zapisano lokalnie. Odbiornik jeszcze nie potwierdził ustawień.")
            }
        } catch { setSettingsStatus(error.localizedDescription, error: true) }
    }

    private func setSettingsStatus(_ text: String, error: Bool = false) {
        settingsStatus = text
        settingsWindow?.setSavedStatus(text, error: error)
    }

    private func refreshReceiverName() {
        let name = appliedReceiverName ?? receiverName
        nameLine.title = name.count > 40 ? String(name.prefix(39)) + "…" : name
        nameLine.toolTip = "Nazwa odbiorcy w AirDrop: " + name
    }

    private func saveAutomatically(id: String, destination: SaveDestination) {
        promptedTransfers.insert(id)
        savingTransfers.insert(id)
        statusLine.title = "Przygotowywanie automatycznego zapisu…"
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
                    self.showError("Folder zapisu jest niedostępny", "Odebrane pliki czekają na zapis. Podłącz dysk lub wybierz inny folder, klikając powiadomienie „Pliki odebrane — wybierz folder” w Centrum powiadomień.")
                }
            }
        }
    }

    private func startSave(id: String, directory: String) {
        guard pendingTransfers[id] != nil, !completedTransfers.contains(id) else { return }
        promptedTransfers.insert(id)
        savingTransfers.insert(id)
        refreshLatestSaveItem()
        if !send(["command": "save", "id": id, "directory": directory]) { saveCouldNotStart(id: id) }
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
        savingTransfers.remove(id)
        progressBanners.remove(id: id)
        if let transfer = pendingTransfers[id] {
            notifications.awaitingDestination(id: id, count: transfer["count"] as? Int ?? 0)
        }
        statusLine.title = "Pliki czekają na zapis"
        refreshLatestSaveItem()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        pairingWindow.close()
        progressBanners.closeAll()
        send(["command": "shutdown"])
        try? input?.close()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = worker, process.isRunning { process.terminate() }
        try? logHandle?.close()
    }

    #if AIRFOLDER_CHECKS
    // Exercise the actual event routing without a network worker or user dialogs.
    func prepareForChecks(defaults: UserDefaults, preferences: AppPreferences, storageDirectory: URL? = nil, reservePicker: Bool = true, command: @escaping ([String: Any]) -> Bool) {
        preferenceStore = PreferencesStore(defaults: defaults)
        self.preferences = preferences
        appliedReceiverName = preferences.receiverName
        appliedAvatarDigest = try? selectedAvatar(preferences).digest
        storageForChecks = storageDirectory
        workerReady = true
        commandForChecks = command
        setupMenu()
        if reservePicker { panel = NSOpenPanel() }  // Reserve without displaying.
    }
    func eventForChecks(_ event: [String: Any]) { receive(event) }
    func requestSaveForChecks(id: String) { requestSave(id: id) }
    func preferencesForChecks(_ preferences: AppPreferences) { applyPreferences(preferences) }
    var pendingIDsForChecks: Set<String> { Set(pendingTransfers.keys) }
    var savingIDsForChecks: Set<String> { savingTransfers }
    var appliedNameForChecks: String? { appliedReceiverName }
    var appliedAvatarForChecks: String? { appliedAvatarDigest }
    var latestSaveIDForChecks: String? { latestSavableID }
    var latestSaveItemForChecks: NSMenuItem { saveLatestItem }
    var currentFolderIDForChecks: String? { currentOffer }
    func cancelFolderForChecks() { panel?.cancel(nil) }
    func closeForChecks() {
        progressBanners.closeAll()
        panel = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
    #endif
}
