// Launch the release's unmodified Python → native helper chain in an isolated
// app identity. Uses the existing research pairing/inbox, never production data.
import Cocoa
import Network

final class DiscoveryChainHost: NSObject, NSApplicationDelegate {
    private var process: Process?
    private var input: FileHandle?
    private var output: Pipe?
    private var log: FileHandle?
    private var buffer = Data()
    private let io = DispatchQueue(label: "pl.aimdrop.discovery-chain-events")
    private let pin = PairingWindowController()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var observers: [NWBrowser] = []
    private var locallySeen = Set<String>()
    private var completed = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.configure(.polish)
        NSApp.setActivationPolicy(.accessory)
        do {
            guard let resources = Bundle.main.resourceURL,
                  let root = Bundle.main.object(forInfoDictionaryKey: "AimDropResearchState") as? String,
                  root.contains("/.build/self-discovery/live") else { throw NSError(domain: "Probe", code: 1) }
            let state = URL(fileURLWithPath: root, isDirectory: true)
            let logURL = state.appendingPathComponent("production-worker.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try FileHandle(forWritingTo: logURL)
            let child = Process()
            child.executableURL = resources.appendingPathComponent("python/bin/python3")
            child.arguments = ["-I", "-B", "-u", resources.appendingPathComponent("receiver/main.py").path,
                "--name=AimDrop AWDL Test", "--language", "pl", "--state-dir", state.path,
                "--native-helper", resources.deletingLastPathComponent().appendingPathComponent("MacOS/AimDropReceiver").path,
                "--native-artwork", resources.appendingPathComponent("AimDropAvatar.png").path,
                "--trash-helper", resources.deletingLastPathComponent().appendingPathComponent("MacOS/AimDropTrash").path,
                "--disable-auto-trash"]
            let incoming = Pipe(), outgoing = Pipe()
            child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = log
            input = incoming.fileHandleForWriting; output = outgoing
            outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.io.async { [weak self] in self?.consume(data) }
            }
            child.terminationHandler = { child in
                DispatchQueue.main.async { [weak self] in
                    self?.label?.stringValue = "Odbiornik zatrzymany (\(child.terminationStatus))"
                    print("production_worker_exited=\(child.terminationStatus)")
                }
            }
            process = child
            try child.run()
            showStatus()
            observe()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { NSApp.terminate(nil) }
        } catch {
            print("production_chain_startup_failed")
            NSApp.terminate(nil)
        }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                buffer.removeSubrange(...newline); continue
            }
            buffer.removeSubrange(...newline)
            DispatchQueue.main.async { [weak self] in self?.event(value) }
        }
    }
    private func event(_ value: [String: Any]) {
        switch value["event"] as? String {
        case "ready":
            label?.stringValue = "AimDrop AWDL Test — gotowy"
            print("production_worker_ready")
        case "discovery_status":
            if let status = value["status"] as? String { print("production_discovery_status=\(status)") }
        case "pairing_pin":
            print("production_pairing_pin_shown")
            if let code = value["code"] as? String { pin.show(code: code) }
        case "pairing_closed": pin.close()
        case "receiving":
            label?.stringValue = "Odbieranie pliku…"
            print("production_transfer_receiving")
        case "downloaded":
            completed += 1
            label?.stringValue = "Plik odebrany — próba zakończona"
            print("production_transfer_downloaded count=\(value["count"] as? Int ?? 0)")
        case "error":
            label?.stringValue = value["message"] as? String ?? "Błąd próby"
            print("production_worker_error fatal=\(value["fatal"] as? Bool ?? false)")
        default: break
        }
    }
    private func showStatus() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "AimDrop 0.8.5 — test odbiornika"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Uruchamianie odbiornika…")
        label.frame = NSRect(x: 24, y: 88, width: 385, height: 30)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        let stop = NSButton(title: "Zakończ próbę", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        ActionButtonStyle.apply(to: stop, autoLayout: false)
        stop.frame = NSRect(x: 145, y: 25, width: 140, height: ActionButtonStyle.height)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(stop)
        panel.center(); panel.orderFrontRegardless()
        self.panel = panel; self.label = label
    }
    private func observe() {
        for type in ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp"] {
            let parameters = NWParameters(); parameters.includePeerToPeer = true
            let observer = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
            observer.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                for result in results {
                    if case .bonjour(let record) = result.metadata, record["dnm"] == "AimDrop AWDL Test",
                       record["sn"] == "com.apple.sharingd.AirDrop", self.locallySeen.insert(type).inserted {
                        print("production_receiver_visible_locally type=\(type)")
                    }
                }
            }
            observer.start(queue: .main); observers.append(observer)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        print("production_chain_result local_types=\(locallySeen.count) received_transfers=\(completed)")
        try? input?.write(contentsOf: Data("{\"command\":\"shutdown\"}\n".utf8))
        try? input?.close()
        observers.forEach { $0.cancel() }
        pin.close()
    }
}

@main struct ProductionDiscoveryCheck {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let host = DiscoveryChainHost()
        app.delegate = host
        app.run()
        withExtendedLifetime(host) {}
    }
}
