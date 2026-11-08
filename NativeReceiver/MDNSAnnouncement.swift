import Foundation

/// Complete, immutable public discovery records. No pairing keys are held here.
struct MDNSAnnouncement: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        let type: String
        let port: UInt16
    }
    let serverID: String
    let txt: [String: String]
    let services: [Service]
    static let lifetime: UInt32 = 6
    // IPv6's minimum MTU (1280), less IPv6 and UDP headers.
    static let maximumPacket = 1232
    enum Invalid: Error { case record }

    init(serverID: String, txt: [String: String], services: [Service]) throws {
        guard UUID(uuidString: serverID) != nil, services.count == 2,
              Set(services.map(\.type)) == ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp"],
              services.allSatisfy({ $0.port > 0 }), txt["sid"] == serverID else { throw Invalid.record }
        self.serverID = serverID; self.txt = txt; self.services = services
        // Validate before publication, including maximum UTF-8 TXT/name sizes.
        _ = try packets(address: Data(repeating: 0, count: 16))
    }
    var instance: String { "AimDrop-" + serverID }
    var host: String { "aimdrop-" + serverID.lowercased() + ".local." }

    func packets(address: Data, ttl: UInt32 = lifetime) throws -> [Data] {
        guard address.count == 16 else { throw Invalid.record }
        var txtData = Data()
        for key in txt.keys.sorted() {
            guard !key.isEmpty, key.utf8.allSatisfy({ (0x20...0x7e).contains($0) && $0 != 0x3d }),
                  let value = txt[key] else { throw Invalid.record }
            let entry = Data((key + "=" + value).utf8)
            guard entry.count <= 255 else { throw Invalid.record }
            txtData.append(UInt8(entry.count)); txtData.append(entry)
        }
        let hostRecord = try Self.record(host, type: 28, data: address, ttl: ttl, unique: true)
        let chains = try services.map { service -> [Data] in
            let type = service.type + ".local."
            let fullName = instance + "." + type
            return [
                try Self.record(type, type: 12, data: Self.name(fullName), ttl: ttl),
                try Self.record(fullName, type: 33, data: Self.integer(UInt16(0)) + Self.integer(UInt16(0))
                    + Self.integer(service.port) + Self.name(host), ttl: ttl, unique: true),
                try Self.record(fullName, type: 16, data: txtData, ttl: ttl, unique: true)
            ]
        }
        let combined = Self.packet(chains.flatMap { $0 } + [hostRecord])
        if combined.count <= Self.maximumPacket { return [combined] }
        // A long localized display name can exceed one IPv6-safe datagram.
        // Each split packet still contains the complete service → host chain.
        let split = chains.map { Self.packet($0 + [hostRecord]) }
        guard split.allSatisfy({ $0.count <= Self.maximumPacket }) else { throw Invalid.record }
        return split
    }
    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func name(_ value: String) throws -> Data {
        var result = Data()
        for label in value.split(separator: ".") {
            let bytes = Data(label.utf8)
            guard (1...63).contains(bytes.count) else { throw Invalid.record }
            result.append(UInt8(bytes.count)); result.append(bytes)
        }
        result.append(0)
        guard result.count <= 255 else { throw Invalid.record }
        return result
    }
    private static func record(_ owner: String, type: UInt16, data: Data, ttl: UInt32, unique: Bool = false) throws -> Data {
        guard let length = UInt16(exactly: data.count) else { throw Invalid.record }
        return try name(owner) + integer(type) + integer(UInt16(unique ? 0x8001 : 1)) + integer(ttl) + integer(length) + data
    }
    private static func packet(_ records: [Data]) -> Data {
        integer(UInt16(0)) + integer(UInt16(0x8400)) + integer(UInt16(0)) + integer(UInt16(records.count))
            + integer(UInt16(0)) + integer(UInt16(0)) + records.reduce(Data(), +)
    }
}
