import Foundation
import CryptoKit

/// One native handshake and its directional encryption counters. No application
/// identity lookup is delegated to CoreUtils: only explicitly enrolled keys.
final class PairVerify: @unchecked Sendable {
    private let engine: AFPairVerify
    private let lock = NSLock()
    private var completed = false

    init(server: Bool, key: Curve25519.Signing.PrivateKey, peers: [Data]) throws {
        // A separate capture avoids retaining this wrapper from its engine.
        let match = VerifiedKey()
        guard let engine = AFCreatePairVerify(server, { data in
            guard data.count == 64 else { return nil }
            return try? key.signature(for: data)
        }, { data, signature in
            guard data.count == 64 else { return false }
            for candidate in peers {
                if let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: candidate),
                   publicKey.isValidSignature(signature, for: data) {
                    return match.accept(candidate)
                }
            }
            return false
        }) else { throw ProbeError.unavailable }
        self.engine = engine
        self.match = match
    }

    private final class VerifiedKey: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func accept(_ key: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value == nil || value == key else { return false }
            value = key
            return true
        }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let match: VerifiedKey

    func exchange(_ data: Data?) async throws -> (data: Data?, verified: Bool) {
        if let data, data.isEmpty || data.count > 65536 { throw ProbeError.invalidArgument }
        let result: (Data?, Bool, Int32) = await withCheckedContinuation { continuation in
            AFPairVerifyExchange(engine, data) { output, verified, error in
                continuation.resume(returning: (output, verified, error))
            }
        }
        guard result.2 == 0 else { throw ProbeError.stage("PairVerify \(result.2)") }
        if result.1 {
            guard match.get() != nil else { throw ProbeError.forbidden }
            markCompleted()
        }
        return (result.0, result.1)
    }

    private func markCompleted() { lock.lock(); completed = true; lock.unlock() }
    var peerKey: Data? {
        lock.lock(); defer { lock.unlock() }
        return completed ? match.get() : nil
    }
    func encrypt(_ data: Data) throws -> Data {
        var error: NSError?
        guard peerKey != nil, let output = AFPairVerifyEncrypt(engine, data, &error) else { throw error ?? ProbeError.forbidden as Error }
        return output
    }
    func decrypt(_ data: Data) throws -> Data {
        var error: NSError?
        guard peerKey != nil, let output = AFPairVerifyDecrypt(engine, data, &error) else { throw error ?? ProbeError.forbidden as Error }
        return output
    }
    func invalidate() { AFPairVerifyInvalidate(engine) }
    deinit { AFPairVerifyInvalidate(engine) }
}

#if !AIRFOLDER_HELPER
func checkPairVerifyEngine() async throws {
    let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey()
    func handshake(wrong: Bool = false) async throws -> (PairVerify, PairVerify) {
        let client = try PairVerify(server: false, key: a, peers: [b.publicKey.rawRepresentation])
        let server = try PairVerify(server: true, key: b, peers: [wrong ? b.publicKey.rawRepresentation : a.publicKey.rawRepresentation])
        let m1 = try await client.exchange(nil)
        guard m1.data != nil, !m1.verified else { throw ProbeError.stage("M1") }
        let m2 = try await server.exchange(m1.data)
        guard m2.data != nil, !m2.verified else { throw ProbeError.stage("M2") }
        let m3 = try await client.exchange(m2.data)
        guard m3.data != nil, !m3.verified else { throw ProbeError.stage("M3") }
        let m4 = try await server.exchange(m3.data)
        guard m4.data != nil, m4.verified else { throw ProbeError.stage("M4 and completion") }
        let done = try await client.exchange(m4.data)
        guard done.data == nil, done.verified,
              client.peerKey == b.publicKey.rawRepresentation, server.peerKey == a.publicKey.rawRepresentation else { throw ProbeError.stage("mutual authentication") }
        return (client, server)
    }
    let (client, server) = try await handshake()
    let plaintext = Data("client QUIC key".utf8)
    let ciphertext = try client.encrypt(plaintext)
    guard ciphertext.count == plaintext.count + 16, try server.decrypt(ciphertext) == plaintext else { throw ProbeError.stage("encrypted request") }
    let response = Data("server QUIC endpoint".utf8)
    guard try client.decrypt(server.encrypt(response)) == response else { throw ProbeError.stage("encrypted response") }
    print("pair_verify_mutual_and_encryption=ok")
    do { _ = try server.decrypt(ciphertext); throw ProbeError.stage("replay accepted") }
    catch ProbeError.stage("replay accepted") { throw ProbeError.stage("replay accepted") }
    catch { print("pair_verify_replay=rejected") }
    do { _ = try await handshake(wrong: true); throw ProbeError.stage("unknown key accepted") }
    catch ProbeError.stage("unknown key accepted") { throw ProbeError.stage("unknown key accepted") }
    catch { print("pair_verify_unknown_key=rejected") }
    let (client2, server2) = try await handshake()
    let (client3, server3) = try await handshake()
    _ = client3
    let crossed = try client2.encrypt(plaintext)
    do { _ = try server3.decrypt(crossed); throw ProbeError.stage("crossed session accepted") }
    catch ProbeError.stage("crossed session accepted") { throw ProbeError.stage("crossed session accepted") }
    catch { print("pair_verify_session_isolation=ok") }
    guard try server2.decrypt(crossed) == plaintext else { throw ProbeError.stage("independent session damaged") }
    print("pair_verify_engine_check=ok")
}
#endif
