// Headless transport owned by the Python worker. Keep module name `rapportd`:
// the distributed RPC names are part of Apple's wire protocol.
import Foundation
import Network
import Darwin

final class HelperEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    init() {
        // Framework diagnostics must never interleave with JSON or expose PINs
        // in the application's log. Only explicit events use the original pipe.
        output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setbuf(stdout, nil)
        signal(SIGPIPE, SIG_IGN)
    }
    func send(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var value = fields; value["event"] = event
        do {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try output.write(contentsOf: data)
        } catch { exit(1) }
    }
    func fatal() -> Never {
        send("error", ["message": "Nie można uruchomić natywnego odbiornika AirDrop. Szczegóły w dzienniku AirFolder."])
        exit(1)
    }
}

func helperName(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: CharacterSet(charactersIn: " ")).precomposedStringWithCanonicalMapping
    guard (1...128).contains(name.utf8.count), !name.unicodeScalars.contains(where: {
        let c = $0.value
        return c <= 0x1f || (0x7f...0x9f).contains(c) || (0x2028...0x202e).contains(c) || (0x2066...0x2069).contains(c)
    }) else { throw ProbeError.invalidArgument }
    return name
}

actor NativeReceiverHost {
    let state: PairingState
    let events: HelperEvents
    let defaultAvatar: ReceiverAvatar
    var systems: [(NWActorSystem, RPPairingDistributedActor, String)] = []
    init(options: [String: String], events: HelperEvents) throws {
        guard let path = options["state-dir"], path.hasPrefix("/"),
              let artwork = options["artwork"], artwork.hasPrefix("/"),
              let name = options["name"], let rawPort = options["backend-port"],
              let port = UInt16(rawPort), port > 0 else { throw ProbeError.invalidArgument }
        self.events = events
        defaultAvatar = try ReceiverAvatar.defaultLogo(at: URL(fileURLWithPath: artwork))
        state = try PairingState(loopback: options["loopback"] == "true",
            directory: URL(fileURLWithPath: path, isDirectory: true), artwork: URL(fileURLWithPath: artwork),
            customAvatar: options["avatar"].map { URL(fileURLWithPath: $0) }, expectedAvatarDigest: options["avatar-digest"],
            name: helperName(name), onPIN: { code in events.send("pin", ["code": code]) },
            onPaired: { events.send("pin_closed") })
        state.files = NativeFileService(port: port)
        state.files?.identity = state.identity
    }
    private func service(type: String) throws -> NWListener.Service {
        guard let tag = AFProbeAuthTag(state.irk, state.serverID, state.dateAdded) else { throw ProbeError.unavailable }
        let txt = NWTXTRecord(["at": tag.map { String(format: "%02x", $0) }.joined(),
            "sid": state.serverID, "sn": state.loopback ? "pl.airfolder.protocolprobe" : "com.apple.sharingd.AirDrop",
            "dnm": state.receiverName])
        return NWListener.Service(name: "AirFolder-" + state.serverID, type: type, txtRecord: txt)
    }
    func start() async throws {
        try await state.files?.start()
        try await publishPairingActors()
        events.send("ready", endpointPorts().merging(["name": state.receiverName, "avatar_digest": state.avatarDigest]) { _, new in new })
    }
    private func publishPairingActors() async throws {
        for (prePair, type) in [(true, "_appSvcPrePair._tcp"), (false, "_applicationServicePairing._tcp")] {
            let system = NWActorSystem(service: try service(type: type), parameters: try serverParameters(state: state, prePair: prePair))
            let actor = RPPairingDistributedActor(state: state, authenticated: !prePair, actorSystem: system)
            systems.append((system, actor, type))
            try await system.publishAndWaitForReady(actor)
            guard let listener = system.listener, listener.port != nil else { throw ProbeError.unavailable }
            let handler = listener.stateUpdateHandler
            listener.stateUpdateHandler = { [events] status in
                handler?(status)
                if case .failed = status { events.fatal() }
            }
        }
    }
    func endpointPorts() -> [String: Any] {
        var ports: [String: Any] = [:]
        for (system, _, type) in systems {
            if let port = system.listener?.port {
                ports[type == "_appSvcPrePair._tcp" ? "prepair_port" : "pairing_port"] = Int(port.rawValue)
            }
        }
        return ports
    }
    private func stopPairingActors() {
        for (system, actor, _) in systems { system.invalidateActor(actor); system.listener?.cancel() }
        systems.removeAll()
    }
    func refreshAdvertisement() throws {
        for (system, _, type) in systems { system.listener?.service = try service(type: type) }
    }
    func updateProfile(_ name: String, avatar: ReceiverAvatar? = nil) async throws -> Bool {
        let changed = try state.updatePresentation(name: helperName(name), avatar: avatar)
        if changed {
            stopPairingActors()
            do { try await publishPairingActors() }
            catch { events.fatal() }
        }
        await state.files?.updateIdentity(state.identity)
        if changed { events.send("pin_closed") }
        return changed
    }
    func setProfile(_ name: String, path: String?, digest: String) async throws -> Bool {
        let selected: ReceiverAvatar
        if let path {
            guard path.hasPrefix("/") else { throw ProbeError.invalidArgument }
            selected = try ReceiverAvatar.read(at: URL(fileURLWithPath: path))
        } else { selected = defaultAvatar }
        guard selected.digest == digest else { throw ProbeError.invalidArgument }
        return try await updateProfile(name, avatar: selected)
    }
    func stop() {
        stopPairingActors()
        state.files?.stop()
        events.send("pin_closed")
    }
}

@main struct AirFolderNativeReceiver {
    static func main() {
        let events = HelperEvents()
        var options: [String: String] = [:]
        for argument in CommandLine.arguments.dropFirst() {
            guard argument.hasPrefix("--"), let split = argument.firstIndex(of: "=") else { events.fatal() }
            options[String(argument[argument.index(argument.startIndex, offsetBy: 2)..<split])] = String(argument[argument.index(after: split)...])
        }
        let commands = AsyncStream<[String: Any]> { continuation in
            DispatchQueue.global().async {
                while let line = readLine() {
                    guard line.utf8.count <= 65536, let data = line.data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    continuation.yield(value)
                }
                // Covers parent death even while listener startup is awaiting
                // the system broker. The OS tears down the helper's listeners.
                exit(0)
            }
        }
        Task {
            do {
                let host = try NativeReceiverHost(options: options, events: events)
                try await host.start()
                let refresh = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                        try await host.refreshAdvertisement()
                    }
                }
                for await command in commands {
                    if command["command"] as? String == "shutdown" { break }
                    let action = command["command"] as? String
                    if action == "set_name" || action == "set_profile", let name = command["name"] as? String,
                       let request = command["request_id"] as? String, UUID(uuidString: request) != nil {
                        do {
                            let changed: Bool
                            if action == "set_profile" {
                                guard let digest = command["avatar_digest"] as? String, command["avatar_path"] != nil else { throw ProbeError.invalidArgument }
                                changed = try await host.setProfile(name, path: command["avatar_path"] as? String, digest: digest)
                            } else { changed = try await host.updateProfile(name) }
                            let ports = await host.endpointPorts()
                            let digest = host.state.avatarDigest
                            events.send(action == "set_profile" ? "profile_result" : "name_result", ports.merging(["request_id": request, "ok": true, "name": name, "avatar_digest": digest, "pairing_reset": changed]) { _, new in new })
                        } catch { events.send(action == "set_profile" ? "profile_result" : "name_result", ["request_id": request, "ok": false]) }
                    }
                }
                refresh.cancel()
                await host.stop()
                exit(0)
            } catch { print("native_receiver_error=\(error)"); events.fatal() }
        }
        dispatchMain()
    }
}
