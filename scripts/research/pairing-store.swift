import Foundation
import CryptoKit
import Security
import Darwin
import Rapport

/// A single locked, atomic store for app-owned identity and PIN-enrolled peers.
/// Missing state creates a new identity; unreadable/corrupt state never does.
final class PairingStore: @unchecked Sendable {
    struct Peer: Codable {
        let identifier: String
        let publicKey: Data
        let irk: Data
        let dateAdded: Date
        let enrolledAt: Date
        let expiresAt: Date
    }
    struct State: Codable {
        var version = 4
        let signingSeed: Data
        let serverID: String
        let deviceID: String
        let irk: Data
        let dateAdded: Date
        var peers: [Peer]
        var presentedName: String? = nil
        var presentedAvatarDigest: String? = nil
    }
    private let lock = NSLock()
    private var state: State
    // v3 donated the original AirFolder logo and did not store its fingerprint.
    // Use that historical image, not whichever logo the current app bundles.
    private static let legacyAvatarDigest = "4f97e97b45d51c2a0c65a11c8d92cda8e9861d3e8bd4d0f9f008cc1ec9e4355e"
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    private static let filename = "identity.json"
    private static let maximumBytes = 1024 * 1024

    init(directory: URL?, name: String, avatarDigest: String) throws {
        // Initialize before calling instance I/O helpers; replace this value
        // only after a complete decode and validation when a file exists.
        state = State(signingSeed: Data(), serverID: "", deviceID: "", irk: Data(), dateAdded: Date(), peers: [])
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw ProbeError.stage("pairing directory unavailable") }
            do {
                var info = stat()
                guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProbeError.stage("pairing directory permissions") }
                lockFD = openat(directoryFD, "identity.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard lockFD >= 0, try checkedFile(lockFD) >= 0,
                      flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ProbeError.stage("pairing store already in use") }
                if let data = try read() {
                    let decoded: State
                    do { decoded = try JSONDecoder().decode(State.self, from: data) }
                    catch { throw ProbeError.stage("pairing store corrupt; identity preserved on disk") }
                    try validate(decoded)
                    state = decoded
                    try updatePresentation(name: name, avatarDigest: avatarDigest)
                    return
                }
            } catch {
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
                close(directoryFD); directoryFD = -1
                throw error
            }
        }
        let date = Date()
        state = State(signingSeed: Curve25519.Signing.PrivateKey().rawRepresentation,
                      serverID: UUID().uuidString, deviceID: UUID().uuidString,
                      irk: try Self.newIRK(date: date), dateAdded: date, peers: [], presentedName: name, presentedAvatarDigest: avatarDigest)
        try save(state)
    }
    deinit {
        if lockFD >= 0 { close(lockFD) }
        if directoryFD >= 0 { close(directoryFD) }
    }

    func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }
    private static func newIRK(date: Date) throws -> Data {
        var irk = Data(count: 16)
        guard irk.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { throw ProbeError.unavailable }
        dlopen("/System/Library/PrivateFrameworks/Rapport.framework/Rapport", RTLD_LAZY | RTLD_GLOBAL)
        return try RPIRKRatchet.dateRatchetIRKData(fromPermanentIRK: irk, for: date)
    }
    @discardableResult func updatePresentation(name: String, avatarDigest: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previousAvatar = state.presentedAvatarDigest ?? Self.legacyAvatarDigest
        if state.version >= 3, state.presentedName == name, previousAvatar == avatarDigest {
            if state.version < 4 {
                // Preserve keys only when the historical name/image really match.
                var migrated = state
                migrated.version = 4
                migrated.presentedAvatarDigest = avatarDigest
                try save(migrated)
                state = migrated
            }
            return false
        }
        let date = Date()
        // iOS can keep authenticating a cached contact when only IRK/UUID change.
        // Name changes require a fully new identity and fresh PIN enrollment.
        // Existing HTTP3 transfers are owned independently by NativeFileService.
        let updated = State(signingSeed: Curve25519.Signing.PrivateKey().rawRepresentation, serverID: UUID().uuidString,
                            deviceID: UUID().uuidString, irk: try Self.newIRK(date: date),
                            dateAdded: date, peers: [], presentedName: name, presentedAvatarDigest: avatarDigest)
        try save(updated)
        state = updated
        return true
    }
    func trustedKeys(now: Date = Date()) -> [Data] {
        snapshot().peers.filter { $0.expiresAt > now }.map(\.publicKey)
    }
    func enroll(_ identities: [RPPairingTemporaryIdentity]) throws {
        guard !identities.isEmpty, identities.count <= 16 else { throw ProbeError.invalidArgument }
        let now = Date()
        // Rapport's default donation lifetime is 30 calendar days
        // (rapportd:0x10011ca04). A new PIN enrollment renews it.
        guard let expiry = Calendar.current.date(byAdding: .day, value: 30, to: now) else { throw ProbeError.unavailable }
        let additions = try identities.map { identity -> Peer in
            guard !identity.identifier.isEmpty, identity.identifier.utf8.count <= 256,
                  identity.deviceIRKData.count == 16, identity.devicePublicKey.count == 32,
                  (identity.contactImageData?.count ?? 0) <= ReceiverAvatar.maximumPNGBytes,
                  identity.dateAdded.timeIntervalSinceReferenceDate.isFinite else { throw ProbeError.invalidArgument }
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: identity.devicePublicKey)
            return Peer(identifier: identity.identifier, publicKey: identity.devicePublicKey,
                        irk: identity.deviceIRKData, dateAdded: identity.dateAdded, enrolledAt: now, expiresAt: expiry)
        }
        lock.lock(); defer { lock.unlock() }
        var updated = state
        updated.peers.removeAll { $0.expiresAt <= now }
        for peer in additions {
            updated.peers.removeAll { $0.publicKey == peer.publicKey }
            updated.peers.append(peer)
        }
        guard updated.peers.count <= 256 else { throw ProbeError.stage("too many paired identities") }
        try save(updated)
        state = updated
    }

    private func validate(_ value: State) throws {
        guard [1, 2, 3, 4].contains(value.version), value.signingSeed.count == 32, value.irk.count == 16,
              UUID(uuidString: value.serverID) != nil, UUID(uuidString: value.deviceID) != nil,
              value.dateAdded.timeIntervalSinceReferenceDate.isFinite, value.peers.count <= 256,
              Set(value.peers.map(\.publicKey)).count == value.peers.count else { throw ProbeError.stage("invalid pairing store") }
        if value.version >= 2 {
            guard let name = value.presentedName, (1...128).contains(name.utf8.count) else { throw ProbeError.stage("invalid pairing name") }
        }
        if value.version >= 4 {
            guard let digest = value.presentedAvatarDigest, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProbeError.stage("invalid avatar fingerprint") }
        }
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: value.signingSeed)
        for peer in value.peers {
            guard !peer.identifier.isEmpty, peer.identifier.utf8.count <= 256,
                  peer.publicKey.count == 32, peer.irk.count == 16,
                  peer.dateAdded.timeIntervalSinceReferenceDate.isFinite,
                  peer.enrolledAt.timeIntervalSinceReferenceDate.isFinite,
                  peer.expiresAt > peer.enrolledAt,
                  peer.expiresAt.timeIntervalSince(peer.enrolledAt) <= 31 * 86400 else { throw ProbeError.stage("invalid paired identity") }
        }
    }
    private func checkedFile(_ fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw ProbeError.stage("pairing file permissions or size") }
        return Int(info.st_size)
    }
    private func read() throws -> Data? {
        let fd = openat(directoryFD, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ProbeError.stage("pairing store unreadable")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let size = try checkedFile(fd)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count == size else { throw ProbeError.stage("pairing store changed during read") }
        return data
    }
    private func save(_ value: State) throws {
        try validate(value)
        guard directoryFD >= 0 else { return }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumBytes else { throw ProbeError.stage("pairing store too large") }
        let name = ".identity-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeError.stage("pairing store write unavailable") }
        defer { unlinkat(directoryFD, name, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard renameat(directoryFD, name, directoryFD, Self.filename) == 0,
              fsync(directoryFD) == 0 else { throw ProbeError.stage("pairing store commit failed") }
    }
}
