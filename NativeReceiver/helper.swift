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
        send("error", ["message": "Nie można uruchomić natywnego odbiornika AirDrop. Szczegóły w dzienniku AimDrop."])
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
    private var advertisement: AWDLAdvertisement?
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
            name: helperName(name), onPIN: { code, expiresAt in
                events.send("pin", ["code": code, "expires_at": expiresAt.timeIntervalSince1970])
            },
            onPaired: { events.send("pin_closed") })
        state.files = NativeFileService(port: port)
        state.files?.identity = state.identity
    }
    private func serviceValues() throws -> [String: String] {
        guard let tag = AFProbeAuthTag(state.irk, state.serverID, state.dateAdded) else { throw ProbeError.unavailable }
        return ["at": tag.map { String(format: "%02x", $0) }.joined(),
            "sid": state.serverID, "sn": state.loopback ? "pl.airfolder.protocolprobe" : "com.apple.sharingd.AirDrop",
            "dnm": state.receiverName]
    }
    private func service(type: String) throws -> NWListener.Service {
        NWListener.Service(name: "AimDrop-" + state.serverID, type: type, txtRecord: NWTXTRecord(try serviceValues()))
    }
    private func announcement() throws -> MDNSAnnouncement {
        let services = try systems.map { system, _, type -> MDNSAnnouncement.Service in
            guard let port = system.listener?.port else { throw ProbeError.unavailable }
            return .init(type: type, port: port.rawValue)
        }
        return try MDNSAnnouncement(serverID: state.serverID, txt: serviceValues(), services: services)
    }
    func start() async throws {
        try await state.files?.start()
        try await publishPairingActors()
        events.send("ready", endpointPorts().merging(["name": state.receiverName, "avatar_digest": state.avatarDigest]) { _, new in new })
        #if AIMDROP_EXPERIMENT_OLD
        events.send("experiment_old") // Makes the two test helpers genuinely different signed code.
        #endif
    }
    private func publishPairingActors() async throws {
        for (prePair, type) in [(true, "_appSvcPrePair._tcp"), (false, "_applicationServicePairing._tcp")] {
            let parameters = try serverParameters(state: state, prePair: prePair)
            let system = state.loopback ? NWActorSystem(service: try service(type: type), parameters: parameters)
                : NWActorSystem(parameters: parameters)
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
        if state.loopback { events.send("discovery_status", ["status": "advertising"]) }
        else { try refreshAdvertisement() }
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
        advertisement?.stop(); advertisement = nil
        for (system, actor, _) in systems { system.invalidateActor(actor); system.listener?.cancel() }
        systems.removeAll()
    }
    func refreshAdvertisement() throws {
        guard systems.count == 2 else { return } // A profile replacement may be awaiting a listener.
        if state.loopback {
            for (system, _, type) in systems { system.listener?.service = try service(type: type) }
        } else {
            do {
                let snapshot = try announcement()
                if let advertisement { advertisement.replace(snapshot) }
                else {
                    let publisher = AWDLAdvertisement(snapshot: snapshot) { [events] status in
                        events.send("discovery_status", ["status": status.rawValue])
                    }
                    advertisement = publisher
                    publisher.start()
                }
            } catch {
                advertisement?.stop(); advertisement = nil
                events.send("discovery_status", ["status": "retrying"])
                throw error
            }
        }
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
    func quiesce(_ request: String) {
        state.files?.quiesce { [events] in events.send("quiesced", ["request_id": request]) }
    }
    func resume() { state.files?.resume() }
    func stop() async {
        stopPairingActors()
        await state.files?.stopAndWait()
        events.send("pin_closed")
    }
}

@main struct AimDropNativeReceiver {
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
                // Give the established host a chance to send goodbye records.
                // The bound still covers parent death during broker startup.
                continuation.yield(["command": "shutdown"])
                continuation.finish()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
            }
        }
        Task {
            do {
                let host = try NativeReceiverHost(options: options, events: events)
                try await host.start()
                let refresh = Task {
                    var previous = AWDLAdvertisement.continuousTime
                    var nextRefresh = previous + 3600
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 5 * 1_000_000_000) }
                        catch { return }
                        let now = AWDLAdvertisement.continuousTime
                        let woke = now - previous > 10
                        previous = now
                        guard woke || now >= nextRefresh else { continue }
                        do {
                            try await host.refreshAdvertisement()
                            nextRefresh = now + 3600
                        } catch {
                            print("native_advertisement_refresh_failed")
                            nextRefresh = now + 5
                        }
                    }
                }
                for await command in commands {
                    if command["command"] as? String == "shutdown" { break }
                    let action = command["command"] as? String
                    if action == "quiesce", let request = command["request_id"] as? String, UUID(uuidString: request) != nil {
                        await host.quiesce(request)
                    } else if action == "resume" { await host.resume() }
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
