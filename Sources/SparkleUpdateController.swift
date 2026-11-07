import Cocoa
import Sparkle

/// Sparkle owns all feed, download, signature and replacement work. This driver
/// owns consent and never treats dismissing a prepared install as cancellation.
final class SparkleUpdateController: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    private let presentation = UpdateWindowController()
    var prepareRestart: ((@escaping (Bool) -> Void) -> Void)?
    var cancelPreparation: (() -> Void)?
    var canCancelPreparation: (() -> Bool)?
    var onManualCheck: (() -> Void)?
    var onPresented: ((AvailableUpdate) -> Void)?
    var log: ((String) -> Void)?
    private var probeCompletion: ((Result<UpdateCheckResult, Error>) -> Void)?
    private var probeResult: UpdateCheckResult = .upToDate
    private var queuedManual = false
    private var cancelAction: (() -> Void)?
    private var cancelRequested = false
    private var consent = false
    private var generation = UUID()
    private var total: UInt64 = 0
    private var received: UInt64 = 0
    private(set) var installing = false
    private(set) var committed = false
    private var started = false
    private var render: (() -> Void)?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: L10n.didChangeNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func languageChanged() { render?() }
    var busy: Bool { updater.sessionInProgress || installing }

    func start() throws { if !started { try updater.start(); started = true } }
    func probe(_ completion: @escaping (Result<UpdateCheckResult, Error>) -> Void) {
        guard !busy else { completion(.failure(UpdateCheckError.busy)); return }
        do { try start() } catch { completion(.failure(error)); return }
        probeResult = .upToDate; probeCompletion = completion
        updater.checkForUpdateInformation()
    }
    func checkManually() {
        if probeCompletion != nil { queuedManual = true; onManualCheck?(); return }
        if busy { showUpdateInFocus(); return }
        do { try start() } catch { showUpdaterError(error, acknowledgement: {}); return }
        cancelRequested = false; consent = false; committed = false; generation = UUID()
        onManualCheck?()
        updater.checkForUpdates()
    }
    private func available(_ item: SUAppcastItem) -> AvailableUpdate {
        let page = item.fullReleaseNotesURL ?? item.infoURL ?? UpdateChecker.productionRepositoryURL
        return AvailableUpdate(version: item.displayVersionString, downloadURL: item.fileURL ?? page, releasePageURL: page, build: item.versionString)
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { probeResult = .available(available(item)) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let completion = probeCompletion {
            probeCompletion = nil
            if let error, (error as NSError).code != SUError.noUpdateError.rawValue { completion(.failure(error)) }
            else { completion(.success(probeResult)) }
        }
        if queuedManual { queuedManual = false; DispatchQueue.main.async { [weak self] in self?.checkManually() } }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelAction = cancellation
        showWorking(L10n.text("Checking for updates…", "Sprawdzanie aktualizacji…"))
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offer(available(appcastItem), informationOnly: appcastItem.isInformationOnlyUpdate, prepared: state.stage == .installing, reply: reply)
    }
    private func offer(_ update: AvailableUpdate, informationOnly: Bool, prepared: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onPresented?(update)
        // A resumed installer can otherwise replace the bundle on ordinary
        // quit even before the user responds to this newly displayed offer.
        installing = prepared
        cancelAction = { reply(prepared ? .skip : .dismiss) }
        render = { [weak self] in
            guard let self else { return }
            self.presentation.show(title: L10n.format("AimDrop %@ is available", "Dostępna jest wersja AimDrop %@", update.version),
                                   message: L10n.text("The app will restart after current operations finish. Your unsaved transfers stay in the inbox.", "Aplikacja uruchomi się ponownie po zakończeniu bieżących operacji. Niezapisane transfery pozostaną w buforze."),
                                   actionTitle: informationOnly ? nil : L10n.text("Update and Restart", "Aktualizuj i uruchom ponownie"), action: { [weak self] in
                guard let self, !self.consent else { return }
                self.consent = true; self.installing = true; self.cancelAction = nil
                if prepared { self.prepare(reply) } else { reply(.install) }
            }, cancelTitle: L10n.text("Later", "Później"), cancel: { [weak self] in self?.cancel() }, releaseURL: update.releasePageURL)
        }
        render?()
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage(L10n.text("No compatible update is available.", "Brak dostępnej zgodnej aktualizacji."), acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        var codes: [String] = []
        func collect(_ error: NSError, depth: Int) {
            guard depth < 8 else { return }
            codes.append("\(error.domain):\(error.code)")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { collect(underlying, depth: depth + 1) }
            for underlying in error.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] ?? [] { collect(underlying, depth: depth + 1) }
        }
        collect(error as NSError, depth: 0)
        log?("Updater error domain=\((error as NSError).domain) code=\((error as NSError).code) causes=\(codes.joined(separator: ","))")
        installing = false; committed = false; cancelPreparation?()
        if codes.contains("SUSparkleErrorDomain:3001") || codes.contains("SUSparkleErrorDomain:3002") {
            showMessage(L10n.text("The update signature is invalid. AimDrop was not replaced. Try again later.", "Podpis aktualizacji jest nieprawidłowy. AimDrop nie został podmieniony. Spróbuj ponownie później."), acknowledgement: acknowledgement)
        } else {
            showMessage(L10n.text("The update could not be completed. Check your connection and available disk space, then try again.", "Nie udało się ukończyć aktualizacji. Sprawdź połączenie i wolne miejsce na dysku, a następnie spróbuj ponownie."), acknowledgement: acknowledgement)
        }
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelAction = cancellation; total = 0; received = 0
        showWorking(L10n.text("Downloading update…", "Pobieranie aktualizacji…"))
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { total = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).partialValue
        presentation.updateProgress(total > 0 ? Double(received) / Double(total) : nil)
    }
    func showDownloadDidStartExtractingUpdate() {
        cancelAction = nil
        showWorking(L10n.text("Verifying and preparing update…", "Weryfikowanie i przygotowywanie aktualizacji…"))
    }
    func showExtractionReceivedProgress(_ progress: Double) { presentation.updateProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard consent, !cancelRequested else { reply(.skip); return }
        prepare(reply)
    }
    private func prepare(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let id = generation
        cancelAction = { reply(.skip) }
        showWorking(L10n.text("Waiting for current operations…", "Oczekiwanie na zakończenie bieżących operacji…"))
        guard let prepareRestart else { cancel(); return }
        prepareRestart { [weak self] ready in
            guard let self, self.generation == id, !self.cancelRequested else { return }
            if !ready { self.cancel(); return }
            self.committed = true; self.cancelAction = nil
            self.showWorking(L10n.text("Installing update…", "Instalowanie aktualizacji…"), cancellable: false)
            reply(.install)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        showWorking(L10n.text("Installing update…", "Instalowanie aktualizacji…"), cancellable: false)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        installing = false; cancelAction = nil
        if !committed { cancelPreparation?() }
        presentation.close()
        render = nil
    }
    func showUpdateInFocus() { presentation.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    func cancel() {
        guard !committed, canCancelPreparation?() != false else { return }
        cancelRequested = true; generation = UUID(); consent = false
        let action = cancelAction; cancelAction = nil
        cancelPreparation?()
        if let action { action() }
        else { showWorking(L10n.text("Canceling update…", "Anulowanie aktualizacji…"), cancellable: false) }
    }
    func showWorking(_ message: @autoclosure @escaping () -> String, cancellable: Bool = true) {
        render = { [weak self] in
            self?.presentation.show(title: L10n.text("AimDrop Update", "Aktualizacja AimDrop"), message: message(), working: true,
                                    cancelTitle: cancellable ? L10n.text("Cancel Update", "Anuluj aktualizację") : nil,
                                    cancel: cancellable ? { [weak self] in self?.cancel() } : nil)
        }
        render?()
    }
    private func showMessage(_ message: @autoclosure @escaping () -> String, acknowledgement: @escaping () -> Void) {
        cancelAction = acknowledgement
        render = { [weak self] in
            self?.presentation.show(title: L10n.text("AimDrop Update", "Aktualizacja AimDrop"), message: message(),
                                    cancelTitle: L10n.text("Close", "Zamknij"), cancel: { [weak self] in
                self?.cancelAction = nil; self?.render = nil; acknowledgement(); self?.presentation.close()
            })
        }
        render?()
    }
    #if AIRFOLDER_CHECKS
    func offerForChecks(_ update: AvailableUpdate, prepared: Bool = false, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offer(update, informationOnly: false, prepared: prepared, reply: reply)
    }
    var windowForChecks: NSWindow { presentation.window! }
    #endif
    #if AIMDROP_UPDATE_EXPERIMENT
    func installForExperiment() { presentation.acceptForExperiment() }
    #endif
}
