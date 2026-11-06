// Standalone PIN-pairing receiver with optional durable identity and HTTP3 bridge.
import Foundation
#if !AIRFOLDER_HELPER
import AppKit
#endif
import Network
import Distributed
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import Rapport

private let pakeContext = "application-service-pairing-context"

struct RPPairingTemporaryIdentity: Codable {
    var contactIdentifier: String?
    var contactImageData: Data?
    var dateAdded: Date
    var deviceName: String
    var identifier: String
    var givenName: String
    var familyName: String
    var deviceIRKData: Data
    var devicePublicKey: Data
}

struct RPPairingIdentity: Codable {
    var deviceName: String
    var identifier: String
    var deviceIRKData: Data
    var devicePublicKey: Data
}

final class RPPairingBonjourResolveResponse: Codable {
    let serverPublicKey: Data
    let bonjourServiceID: String
}

enum ProbeError: Error { case unavailable, forbidden, transferUnavailable, invalidArgument, stage(String) }

final class PairingState: @unchecked Sendable {
    let lock = NSLock()
    let store: PairingStore
    private var key: Curve25519.Signing.PrivateKey
    var signingKey: Curve25519.Signing.PrivateKey { lock.lock(); defer { lock.unlock() }; return key }
    var serverID: String { store.snapshot().serverID }
    var deviceID: String { store.snapshot().deviceID }
    var dateAdded: Date { store.snapshot().dateAdded }
    var irk: Data { store.snapshot().irk }
    private var avatar: ReceiverAvatar
    var image: Data { lock.lock(); defer { lock.unlock() }; return avatar.png }
    var avatarDigest: String { lock.lock(); defer { lock.unlock() }; return avatar.digest }
    let loopback: Bool
    private var pin = ""
    private var pinExpires = Date.distantPast
    private var name: String
    let onPIN: ((String) -> Void)?
    let onPaired: (() -> Void)?
    var credentials: [String: (sec_identity_t, Date)] = [:]
    var files: NativeFileService?

    init(loopback: Bool, directory: URL? = nil, artwork: URL? = nil, customAvatar: URL? = nil, expectedAvatarDigest: String? = nil,
         name: String = "AirFolder Logo Test", onPIN: ((String) -> Void)? = nil,
         onPaired: (() -> Void)? = nil) throws {
        self.loopback = loopback
        self.name = name; self.onPIN = onPIN; self.onPaired = onPaired
        // Validate the complete image before creating or modifying identity.
        let baseline = try ReceiverAvatar.defaultLogo(at: artwork ?? URL(fileURLWithPath: ".build/artwork/AirFolder.png"))
        avatar = try customAvatar.map { try ReceiverAvatar.read(at: $0) } ?? baseline
        guard expectedAvatarDigest == nil || expectedAvatarDigest == avatar.digest else { throw ProbeError.invalidArgument }
        store = try PairingStore(directory: directory ?? ProcessInfo.processInfo.environment["AIRFOLDER_PAIRING_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                                 name: name, avatarDigest: avatar.digest, defaultAvatarDigest: baseline.digest)
        let stored = store.snapshot()
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.signingSeed)
    }

    func register(client: String) throws -> String {
        guard !client.isEmpty, client.utf8.count <= 256 else { throw ProbeError.invalidArgument }
        lock.lock()
        credentials = credentials.filter { $0.value.1 > Date() }
        guard credentials.count < 16 else { lock.unlock(); throw ProbeError.forbidden }
        if pinExpires <= Date() {
            let previous = pin
            repeat { pin = String(format: "%06d", Int.random(in: 0..<1_000_000)) } while pin == previous
            pinExpires = Date().addingTimeInterval(120)
        }
        let code = pin
        let server = UUID().uuidString
        guard let credential = AFCreateSPAKEIdentity(pakeContext, client, server, code, true) else { lock.unlock(); throw ProbeError.unavailable }
        credentials[client + ":" + server] = (credential, pinExpires)
        lock.unlock()
        print("prepair_exchange=ready")
        #if !AIRFOLDER_HELPER
        if loopback { print("test_pin=\(code)") }
        else { DispatchQueue.main.async { PINPanel.show(pin: code) } }
        #endif
        onPIN?(code)
        return server
    }

    func credential(client: String, server: String) -> sec_identity_t? {
        lock.lock()
        defer { lock.unlock() }
        credentials = credentials.filter { $0.value.1 > Date() }
        let identity = credentials[client + ":" + server]?.0
        print("pake_credential_lookup=\(identity == nil ? "miss" : "hit")")
        return identity
    }

    var identity: RPPairingTemporaryIdentity {
        lock.lock(); defer { lock.unlock() }
        let saved = store.snapshot()
        return RPPairingTemporaryIdentity(contactImageData: avatar.png, dateAdded: saved.dateAdded,
            deviceName: name, identifier: saved.deviceID, givenName: name, familyName: "",
            deviceIRKData: saved.irk, devicePublicKey: key.publicKey.rawRepresentation)
    }

    var receiverName: String { lock.lock(); defer { lock.unlock() }; return name }
    func updatePresentation(name value: String, avatar updatedAvatar: ReceiverAvatar? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let selected = updatedAvatar ?? avatar
        let changed = try store.updatePresentation(name: value, avatarDigest: selected.digest)
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: store.snapshot().signingSeed)
        name = value
        avatar = selected
        if changed { credentials.removeAll(); pinExpires = .distantPast }
        return changed
    }

}

#if !AIRFOLDER_HELPER
@MainActor enum PINPanel {
    static var panel: NSPanel?
    static var heading: NSTextField?
    static var detail: NSTextField?
    static func show(pin: String? = nil) {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "AirFolder — test ikony"
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let heading = NSTextField(labelWithString: "")
            heading.frame = NSRect(x: 24, y: 138, width: 375, height: 24)
            let detail = NSTextField(labelWithString: "")
            detail.frame = NSRect(x: 24, y: 62, width: 375, height: 60)
            let stop = NSButton(title: "Zakończ próbę", target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
            stop.frame = NSRect(x: 135, y: 15, width: 150, height: 30)
            stop.bezelStyle = .rounded
            window.contentView?.addSubview(heading)
            window.contentView?.addSubview(detail)
            window.contentView?.addSubview(stop)
            window.center()
            panel = window
            self.heading = heading
            self.detail = detail
        }
        heading?.stringValue = pin == nil ? "Odbiornik testowy jest aktywny" : "Wpisz ten kod na iPhonie"
        detail?.font = pin == nil ? .systemFont(ofSize: 18, weight: .medium) : .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        detail?.stringValue = pin ?? "AirFolder Logo Test"
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        print(pin == nil ? "status_panel_shown" : "pin_panel_shown")
    }

    static func transferReady() {
        heading?.stringValue = "Kod przyjęty — oczekiwanie na plik"
        detail?.font = .systemFont(ofSize: 18, weight: .medium)
        detail?.stringValue = "Połączenie do transferu gotowe"
    }
}
#endif

distributed actor RPPairingDistributedActor: NWSingletonPublishedActor {
    typealias ActorSystem = NWActorSystem
    let state: PairingState
    let authenticated: Bool
    var verifySessions: [UUID: VerifySession] = [:]
    var legacySessionID: UUID?
    init(state: PairingState, authenticated: Bool, actorSystem: NWActorSystem) {
        self.state = state
        self.authenticated = authenticated
        self.actorSystem = actorSystem
    }

    distributed func exchangePAKEIdentities(clientIdentity: String, deviceName: String, givenName: String?, familyName: String?) async throws -> String {
        guard !authenticated else { throw ProbeError.forbidden }
        return try state.register(client: clientIdentity)
    }

    distributed func pairAndReceiveTemporaryIdentities(pairingData: Data) async throws -> [RPPairingTemporaryIdentity]? {
        guard authenticated else { throw ProbeError.forbidden }
        print("authenticated_identity_sent image_bytes=\(state.image.count) pairing_data_bytes=\(pairingData.count)")
        return [state.identity]
    }

    distributed func shareTemporaryIdentities(_ identities: [RPPairingTemporaryIdentity]) async throws {
        guard authenticated else { throw ProbeError.forbidden }
        try state.store.enroll(identities)
        state.onPaired?()
        print("authenticated_peer_identities_received count=\(identities.count)")
    }

    distributed func resolveBonjour(clientPublicKey: Data) async throws -> RPPairingBonjourResolveResponse {
        guard authenticated, let files = state.files else { throw ProbeError.transferUnavailable }
        let response = try await files.resolve(publicKey: clientPublicKey)
        #if !AIRFOLDER_HELPER
        DispatchQueue.main.async { PINPanel.transferReady() }
        #endif
        print("authenticated_file_endpoint_delivered")
        return response
    }

    distributed func startPairVerifyWithSessionID(createEncryptionStream: Bool) async throws -> UUID {
        try newVerifySession(createEncryptionStream: createEncryptionStream)
    }
    distributed func processPairVerifyDataWithSessionID(_ data: Data, sessionID: UUID) async throws -> Data? {
        try await processVerify(data, sessionID: sessionID)
    }
    distributed func resolveBonjourEncryptedWithSessionID(encryptedRequest: Data, sessionID: UUID) async throws -> Data {
        try await encryptedResolve(encryptedRequest, sessionID: sessionID)
    }
    distributed func startPairVerify(createEncryptionStream: Bool) async throws {
        pruneVerifySessions()
        guard legacySessionID == nil else { throw ProbeError.forbidden }
        legacySessionID = try newVerifySession(createEncryptionStream: createEncryptionStream)
    }
    distributed func processPairVerifyData(_ data: Data) async throws -> Data? {
        guard let id = legacySessionID else { throw ProbeError.forbidden }
        return try await processVerify(data, sessionID: id)
    }
    distributed func resolveBonjourEncrypted(encryptedRequest: Data) async throws -> Data {
        guard let id = legacySessionID else { throw ProbeError.forbidden }
        return try await encryptedResolve(encryptedRequest, sessionID: id)
    }
    distributed func resolveBonjourCompleted() async throws {
        // The native callback carries no UUID. It cannot safely select a UUID
        // session; those are bounded and expire independently.
        if let id = legacySessionID, verifySessions[id]?.busy == false { removeVerifySession(id) }
    }

    struct VerifySession {
        let engine: PairVerify
        let stream: Bool
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var busy = false
    }
    func removeVerifySession(_ id: UUID) {
        verifySessions.removeValue(forKey: id)?.engine.invalidate()
        if legacySessionID == id { legacySessionID = nil }
    }
    func pruneVerifySessions() {
        for (id, session) in verifySessions where session.deadline < ProcessInfo.processInfo.systemUptime { removeVerifySession(id) }
    }
    func newVerifySession(createEncryptionStream: Bool) throws -> UUID {
        guard !authenticated else { throw ProbeError.forbidden }
        pruneVerifySessions()
        guard verifySessions.count < 16 else { throw ProbeError.forbidden }
        let id = UUID()
        verifySessions[id] = VerifySession(engine: try PairVerify(server: true, key: state.signingKey, peers: state.store.trustedKeys()), stream: createEncryptionStream)
        return id
    }
    func processVerify(_ data: Data, sessionID id: UUID) async throws -> Data? {
        pruneVerifySessions()
        guard !authenticated, let session = verifySessions[id], !session.busy, session.engine.peerKey == nil else { throw ProbeError.forbidden }
        verifySessions[id]?.busy = true
        do {
            let result = try await session.engine.exchange(data)
            guard verifySessions[id] != nil else { throw ProbeError.forbidden }
            verifySessions[id]?.busy = false
            if result.verified { print("pair_verify_authenticated") }
            return result.data
        } catch { removeVerifySession(id); throw error }
    }
    func encryptedResolve(_ request: Data, sessionID id: UUID) async throws -> Data {
        pruneVerifySessions()
        guard !authenticated, let session = verifySessions[id], session.stream, !session.busy,
              let key = session.engine.peerKey, state.store.trustedKeys().contains(key),
              request.count >= 16, request.count <= 65536, let files = state.files else { throw ProbeError.forbidden }
        verifySessions[id]?.busy = true
        do {
            let publicKey = try session.engine.decrypt(request)
            guard !publicKey.isEmpty, publicKey.count <= 16384 else { throw ProbeError.invalidArgument }
            let response = try await files.resolve(publicKey: publicKey)
            guard verifySessions[id] != nil else { throw ProbeError.forbidden }
            let encrypted = try session.engine.encrypt(JSONEncoder().encode(response))
            verifySessions[id]?.busy = false
            print("pair_verify_encrypted_endpoint_delivered")
            #if !AIRFOLDER_HELPER
            if !state.loopback { DispatchQueue.main.async { PINPanel.transferReady() } }
            #endif
            return encrypted
        } catch { removeVerifySession(id); throw error }
    }
}

func modernTLS() throws -> NWProtocolTLS.Options {
    guard let raw = AFCreateTLSRecordOptions(), let tls = NWProtocolOptions.fromNW(raw) as? NWProtocolTLS.Options else { throw ProbeError.stage("Swift TLS options") }
    return tls
}

func serverParameters(state: PairingState, prePair: Bool) throws -> NWParameters {
    let tls = try prePair ? NWProtocolTLS.Options() : modernTLS()
    if prePair {
        guard let identity = AFCreatePrePairIdentity() else { throw ProbeError.stage("self-signed pre-pair identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        guard AFSetPeerAuthenticationOptional(tls.securityProtocolOptions) else { throw ProbeError.unavailable }
    } else {
        guard AFConfigurePAKEChallenge(tls.securityProtocolOptions, { client, server in
            state.credential(client: client, server: server)
        }) else { throw ProbeError.unavailable }
    }
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 10
    let parameters = NWParameters(tls: tls, tcp: tcp)
    if state.loopback { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
    else { parameters.includePeerToPeer = true }
    return parameters
}

#if !AIRFOLDER_HELPER
func runServer(loopback: Bool) async throws {
    let state = try PairingState(loopback: loopback)
    if !loopback || ProcessInfo.processInfo.environment["AIRFOLDER_PAIRING_TEST_FILES"] == "1" {
        let files = NativeFileService()
        files.identity = state.identity
        try await files.start()
        state.files = files
    }
    guard let authTag = AFProbeAuthTag(state.irk, state.serverID, state.dateAdded) else { throw ProbeError.stage("auth tag") }
    let txt = NWTXTRecord([
        "at": authTag.map { String(format: "%02x", $0) }.joined(),
        "sid": state.serverID,
        "sn": loopback ? "pl.airfolder.protocolprobe" : "com.apple.sharingd.AirDrop",
        "dnm": "AirFolder Logo Test"
    ])
    var systems: [NWActorSystem] = []
    var actors: [RPPairingDistributedActor] = []
    for (prePair, type) in [(true, "_appSvcPrePair._tcp"), (false, "_applicationServicePairing._tcp")] {
        let service = NWListener.Service(name: "AirFolder-" + state.serverID, type: type, txtRecord: txt)
        let system = NWActorSystem(service: service, parameters: try serverParameters(state: state, prePair: prePair))
        let actor = RPPairingDistributedActor(state: state, authenticated: !prePair, actorSystem: system)
        try await system.publishAndWaitForReady(actor)
        guard let port = system.listener?.port else { throw ProbeError.unavailable }
        print("\(prePair ? "prepair" : "pairing")_server_ready port=\(port.rawValue)")
        systems.append(system)
        actors.append(actor)
    }
    print("pairing_prototype_ready scope=\(loopback ? "loopback" : "awdl")")
    print("paired_identity_count=\(state.store.trustedKeys().count)")
    if !loopback { DispatchQueue.main.async { PINPanel.show() } }
    try await Task.sleep(nanoseconds: UInt64(loopback ? 180 : 3600) * 1_000_000_000)
    for (system, actor) in zip(systems, actors) {
        system.invalidateActor(actor)
        system.listener?.cancel()
    }
}

func runClient(prePairPort: UInt16, pairingPort: UInt16, wrongPIN: Bool) async throws {
    let tls = NWProtocolTLS.Options()
    // This discovery connection carries PAKE identifiers, not authenticated identities.
    // Rapport accepts the self-signed pre-pair certificate in the same way.
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
    let discoveryParameters = NWParameters(tls: tls)
    let client = NWActorSystem(parameters: discoveryParameters)
    let prePair = try RPPairingDistributedActor.discover(.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: prePairPort)!), connectionParameters: discoveryParameters, using: client, invalidationHandler: nil)
    guard __isRemoteActor(prePair) else { throw ProbeError.unavailable }
    do {
        _ = try await prePair.pairAndReceiveTemporaryIdentities(pairingData: Data())
        print("unauthenticated_identity_unexpectedly_returned")
        exit(1)
    } catch { print("unauthenticated_identity_request=rejected") }
    let clientID = UUID().uuidString
    let serverID = try await prePair.exchangePAKEIdentities(clientIdentity: clientID, deviceName: "AirFolder Loopback Client", givenName: nil, familyName: nil)
    print("prepair_client_exchange=ok")
    guard var pin = readLine(), pin.count == 6 else { throw ProbeError.invalidArgument }
    if wrongPIN {
        pin = String(pin.prefix(5)) + String((Int(String(pin.last!))! + 1) % 10)
    }
    guard let credential = AFCreateSPAKEIdentity(pakeContext, clientID, serverID, pin, false) else { throw ProbeError.unavailable }
    let authenticatedTLS = try modernTLS()
    sec_protocol_options_set_local_identity(authenticatedTLS.securityProtocolOptions, credential)
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 5
    let parameters = NWParameters(tls: authenticatedTLS, tcp: tcp)
    let authenticatedSystem = NWActorSystem(parameters: parameters)
    let peer = try RPPairingDistributedActor.discover(.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: pairingPort)!), connectionParameters: parameters, using: authenticatedSystem, invalidationHandler: nil)
    let identities: [RPPairingTemporaryIdentity]?
    do {
        identities = try await peer.pairAndReceiveTemporaryIdentities(pairingData: Data(pin.utf8))
    } catch {
        if wrongPIN { print("dynamic_wrong_pin=rejected \(error)"); return }
        throw error
    }
    guard !wrongPIN else { print("dynamic_wrong_pin=unexpectedly_accepted"); exit(1) }
    let own = try PairingState(loopback: true)
    let expectedImage = try ProcessInfo.processInfo.environment["AIRFOLDER_EXPECTED_AVATAR"].map { try ReceiverAvatar.read(at: URL(fileURLWithPath: $0)).png } ?? own.image
    guard let identity = identities?.first,
          identity.deviceName == ProcessInfo.processInfo.environment["AIRFOLDER_EXPECTED_NAME"] ?? "AirFolder Logo Test",
          identity.contactImageData == expectedImage else { throw ProbeError.unavailable }
    try own.store.enroll(identities!)
    print("dynamic_pake_logo_exchange=ok bytes=\(own.image.count)")
    try await peer.shareTemporaryIdentities([own.identity])
    print("temporary_identity_exchange=mutual")
}

@main struct Prototype {
    static func main() {
        setbuf(stdout, nil)
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--pairing-store-check"] {
            do { _ = try PairingState(loopback: true); print("pairing_store_check=ok"); exit(0) }
            catch { print("pairing_store_check_error=\(error)"); exit(1) }
        }
        if args.first == "--reconnect", args.count == 3, let port = UInt16(args[1]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(8) }
            Task {
                do { try await checkPairVerifyReconnect(port: port, mode: args[2]); exit(0) }
                catch { print("reconnect_check_error=\(error)"); exit(1) }
            }
            dispatchMain()
        }
        if args == ["--pair-verify-check"] {
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { exit(8) }
            Task {
                do { try await checkPairVerifyEngine(); exit(0) }
                catch { print("pair_verify_check_error=\(error)"); exit(1) }
            }
            dispatchMain()
        }
        if args == ["--native-resolve-check"] || (["--native-transfer-check", "--native-cancel-check"].contains(args.first ?? "") && args.count == 2) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(8) }
            Task {
                let files = NativeFileService()
                do {
                    try await files.start()
                    guard let parameters = AFCreateHTTP3ClientParameters(), let key = AFQUICPublicKey(parameters) else { throw ProbeError.stage("client public key") }
                    let response = try await files.resolve(publicKey: key)
                    print("native_resolve_check=ok")
                    func post(_ path: String, _ body: Data, headers: [String: String], expected: UInt32 = 200) async throws -> Data {
                        let (status, data, returnedHeaders, error): (UInt32, Data, [String: String], Int32) = await withCheckedContinuation { continuation in
                            AFHTTP3Check(parameters, response.bonjourServiceID, response.serverPublicKey, path, body, headers) { status, data, headers, error in
                                continuation.resume(returning: (status, data, headers, error))
                            }
                        }
                        if expected == 0 {
                            guard error != 0 && error != -3 else { throw ProbeError.stage("expected prompt stream cancellation, status=\(status) error=\(error)") }
                            return data
                        }
                        guard status == expected && error == 0 else { throw ProbeError.stage("HTTP3 \(path) status=\(status) error=\(error)") }
                        if !data.isEmpty && status == 200 {
                            guard returnedHeaders["content-type"] == "application/x-apple-binary-plist" else { throw ProbeError.stage("response content-type") }
                        }
                        return data
                    }
                    let plistHeaders = ["content-type": "application/x-apple-binary-plist"]
                    let data = try await post("/Discover", PropertyListSerialization.data(fromPropertyList: [:], format: .binary, options: 0), headers: plistHeaders)
                    guard let discovery = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          discovery["ReceiverComputerName"] as? String == "AirFolder Logo Test",
                          discovery["ReceiverMediaCapabilities"] is Data else { throw ProbeError.stage("forwarded discovery plist") }
                    print("native_http3_discover_check=ok")
                    if args.first == "--native-transfer-check" || args.first == "--native-cancel-check" {
                        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
                        let ask = try Data(contentsOf: directory.appendingPathComponent("ask.plist"))
                        let metadata = try PropertyListSerialization.propertyList(from: ask, format: nil) as! [String: Any]
                        guard let transfer = (metadata["TransferID"] as? String) ?? (metadata["TransferID"] as? [String: String])?["id"] else { throw ProbeError.stage("fixture TransferID") }
                        _ = try await post("/Ask", ask, headers: plistHeaders)
                        print("native_http3_ask_check=ok")
                        let payload = try Data(contentsOf: directory.appendingPathComponent("upload.body"))
                        let uploadHeaders = ["content-type": "application/x-dvzip", "transferid": transfer, "expect": "100-continue"]
                        let canceled = args.first == "--native-cancel-check"
                        _ = try await post("/Upload", payload, headers: uploadHeaders, expected: canceled ? 0 : 200)
                        if canceled { print("native_http3_cancel_check=ok") }
                        else {
                            print("native_http3_upload_check=ok")
                            _ = try await post("/Upload", payload, headers: uploadHeaders, expected: 403)
                            print("native_http3_replay_check=rejected")
                        }
                    }
                    files.stop()
                    exit(0)
                } catch { print("native_resolve_error=\(error)"); files.stop(); exit(1) }
            }
            dispatchMain()
        }
        if args.first == "--client", args.count >= 3, let pre = UInt16(args[1]), let pair = UInt16(args[2]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) { exit(8) }
            Task {
                do { try await runClient(prePairPort: pre, pairingPort: pair, wrongPIN: args.contains("--wrong-pin")); exit(0) }
                catch { print("pairing_client_error=\(error)"); exit(1) }
            }
            dispatchMain()
        }
        guard args == ["--loopback"] || args == ["--advertise"] else {
            print("Usage: pairing-prototype --loopback|--advertise")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let loopback = args == ["--loopback"]
        DispatchQueue.global().asyncAfter(deadline: .now() + (loopback ? 185 : 3605)) { exit(8) }
        Task {
            do { try await runServer(loopback: loopback); exit(0) }
            catch { print("pairing_prototype_error=\(error)"); exit(1) }
        }
        app.run()
    }
}
#endif
