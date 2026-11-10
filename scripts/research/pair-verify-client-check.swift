import Foundation
import CryptoKit
import Network

/// Receiver limits apply to stored credentials, not unused native contact photos.
func checkPeerEnrollment() throws {
    let store = try PairingStore(directory: nil, name: "Peer fixture", avatarDigest: String(repeating: "0", count: 64))
    func identity(imageBytes: Int) -> RPPairingTemporaryIdentity {
        RPPairingTemporaryIdentity(contactImageData: Data(repeating: 0xa5, count: imageBytes), dateAdded: Date(),
            deviceName: "Synthetic Mac", identifier: UUID().uuidString, givenName: "Fixture", familyName: "",
            deviceIRKData: Data(repeating: 1, count: 16), devicePublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }
    let nativeSized = identity(imageBytes: 551_006)
    let larger = identity(imageBytes: 2 * 1024 * 1024)
    try store.enroll([nativeSized, larger])
    precondition(Set(store.trustedKeys()) == Set([nativeSized.devicePublicKey, larger.devicePublicKey]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(store.snapshot())
    precondition(before.count < 16_384, "Peer photos must not enter persistent pairing storage")

    func reject(_ identities: [RPPairingTemporaryIdentity]) throws {
        var rejected = false
        do { try store.enroll(identities) } catch ProbeError.invalidArgument { rejected = true }
        precondition(rejected, "Malformed credentials must still be rejected")
        let after = try encoder.encode(store.snapshot())
        precondition(after == before, "Rejected batches must not partially update stored peers")
    }
    try reject([])
    try reject(Array(repeating: nativeSized, count: 17))
    var invalid = nativeSized
    invalid.identifier = ""
    try reject([larger, invalid])
    invalid = nativeSized; invalid.identifier = String(repeating: "x", count: 257)
    try reject([invalid])
    invalid = nativeSized; invalid.deviceIRKData = Data(count: 15)
    try reject([invalid])
    invalid = nativeSized; invalid.devicePublicKey = Data(count: 31)
    try reject([invalid])
    invalid = nativeSized; invalid.dateAdded = Date(timeIntervalSinceReferenceDate: .nan)
    try reject([invalid])
    print("peer_enrollment_large_contact_photo=ok credential_validation_and_atomicity=ok")
}

/// Cross-process fixture: the server and client have separate persistent stores.
/// Uses the real pre-pair actor, native handshake and native QUIC endpoint.
func checkPairVerifyReconnect(port: UInt16, mode: String) async throws {
    let own = try PairingState(loopback: true)
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .global())
    let parameters = NWParameters(tls: tls)
    let system = NWActorSystem(parameters: parameters)
    let peer = try RPPairingDistributedActor.discover(.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!), connectionParameters: parameters, using: system, invalidationHandler: nil)
    let legacy = mode == "legacy"
    func handshake(stream: Bool = true) async throws -> (UUID, PairVerify) {
        let id: UUID
        if legacy { try await peer.startPairVerify(createEncryptionStream: stream); id = UUID() }
        else { id = try await peer.startPairVerifyWithSessionID(createEncryptionStream: stream) }
        let engine = try PairVerify(server: false, key: mode == "wrong-key" ? Curve25519.Signing.PrivateKey() : own.signingKey, peers: own.store.trustedKeys())
        func exchange(_ data: Data) async throws -> Data? {
            if legacy { return try await peer.processPairVerifyData(data) }
            return try await peer.processPairVerifyDataWithSessionID(data, sessionID: id)
        }
        let m1 = try await engine.exchange(nil)
        guard let m1 = m1.data, let m2 = try await exchange(m1) else { throw ProbeError.stage("remote M2 missing") }
        let m3 = try await engine.exchange(m2)
        guard let m3 = m3.data, let m4 = try await exchange(m3) else { throw ProbeError.stage("remote M4 missing") }
        let complete = try await engine.exchange(m4)
        guard complete.verified else { throw ProbeError.stage("remote authentication incomplete") }
        return (id, engine)
    }
    func reject(_ label: String, _ operation: () async throws -> Void) async throws {
        var rejected = false
        do { try await operation() } catch { rejected = true }
        guard rejected else { throw ProbeError.stage(label + " accepted") }
        print("\(label)=rejected")
    }
    if ["wrong-key", "expired"].contains(mode) {
        try await reject("reconnect_" + mode) { _ = try await handshake() }
        return
    }
    try await reject("resolve_before_verify") {
        _ = try await peer.resolveBonjourEncryptedWithSessionID(encryptedRequest: Data(repeating: 0, count: 64), sessionID: UUID())
    }
    let (id, engine) = try await handshake(stream: mode != "no-stream")
    guard let quic = AFCreateHTTP3ClientParameters(), let clientKey = AFQUICPublicKey(quic) else { throw ProbeError.unavailable }
    let request = try engine.encrypt(clientKey)
    func resolve(_ ciphertext: Data, id: UUID) async throws -> Data {
        if legacy { return try await peer.resolveBonjourEncrypted(encryptedRequest: ciphertext) }
        return try await peer.resolveBonjourEncryptedWithSessionID(encryptedRequest: ciphertext, sessionID: id)
    }
    if mode == "no-stream" {
        try await reject("resolve_without_stream") { _ = try await resolve(request, id: id) }
        return
    }
    if legacy {
        try await reject("legacy_overlap") { try await peer.startPairVerify(createEncryptionStream: true) }
    }
    if mode == "isolation" {
        let (other, _) = try await handshake()
        try await reject("cross_session_resolve") { _ = try await resolve(request, id: other) }
    }
    let encrypted = try await resolve(request, id: id)
    let response = try JSONDecoder().decode(RPPairingBonjourResolveResponse.self, from: engine.decrypt(encrypted))
    guard !response.serverPublicKey.isEmpty, UUID(uuidString: response.bonjourServiceID) != nil else { throw ProbeError.stage("encrypted endpoint shape") }
    let body = try PropertyListSerialization.data(fromPropertyList: [:], format: .binary, options: 0)
    let result: (UInt32, Data, Int32) = await withCheckedContinuation { continuation in
        AFHTTP3Check(quic, response.bonjourServiceID, response.serverPublicKey, "/Discover", body, ["content-type": "application/x-apple-binary-plist"]) { status, data, _, error in
            continuation.resume(returning: (status, data, error))
        }
    }
    guard result.0 == 200, result.2 == 0,
          let plist = try PropertyListSerialization.propertyList(from: result.1, format: nil) as? [String: Any],
          plist["ReceiverEdPKData"] as? Data == engine.peerKey else { throw ProbeError.stage("reconnected QUIC identity") }
    print("restart_pair_verify_http3=ok")
    if let name = ProcessInfo.processInfo.environment["AIRFOLDER_EXPECTED_NAME"] {
        guard plist["ReceiverComputerName"] as? String == name else { throw ProbeError.stage("reconnected receiver name") }
    }
    if let path = ProcessInfo.processInfo.environment["AIRFOLDER_RECONNECT_TRANSFER_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let ask = try Data(contentsOf: directory.appendingPathComponent("ask.plist"))
        let metadata = try PropertyListSerialization.propertyList(from: ask, format: nil) as! [String: Any]
        guard let transfer = (metadata["TransferID"] as? String) ?? (metadata["TransferID"] as? [String: String])?["id"] else { throw ProbeError.invalidArgument }
        for (path, data, headers) in [
            ("/Ask", ask, ["content-type": "application/x-apple-binary-plist"]),
            ("/Upload", try Data(contentsOf: directory.appendingPathComponent("upload.body")), ["content-type": "application/x-dvzip", "transferid": transfer, "expect": "100-continue"])
        ] {
            // AFHTTP3Check opens a new QUIC connection per request (the phone
            // normally multiplexes streams). Authorize that connection's fresh
            // key instead of relying on reusable/resumed fixture parameters.
            guard let transferQUIC = AFCreateHTTP3ClientParameters(), let transferKey = AFQUICPublicKey(transferQUIC) else { throw ProbeError.unavailable }
            let endpoint = try JSONDecoder().decode(RPPairingBonjourResolveResponse.self,
                from: engine.decrypt(await resolve(engine.encrypt(transferKey), id: id)))
            let result: (UInt32, Int32) = await withCheckedContinuation { continuation in
                AFHTTP3Check(transferQUIC, endpoint.bonjourServiceID, endpoint.serverPublicKey, path, data, headers) { status, _, _, error in
                    continuation.resume(returning: (status, error))
                }
            }
            guard result.0 == 200, result.1 == 0 else { throw ProbeError.stage("reconnected \(path) status=\(result.0) error=\(result.1)") }
        }
        print("bundled_pair_verify_transfer=ok")
    }
    if mode == "replay" {
        try await reject("encrypted_resolve_replay") { _ = try await resolve(request, id: id) }
        try await reject("failed_session_reuse") { _ = try await resolve(engine.encrypt(clientKey), id: id) }
    }
    try await peer.resolveBonjourCompleted()
    if legacy {
        _ = try await handshake()
        try await peer.resolveBonjourCompleted()
        print("legacy_second_session=ok")
    }
}
