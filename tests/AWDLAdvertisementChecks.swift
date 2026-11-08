import Foundation
import Darwin

private struct Record {
    let name: String
    let type: Int
    let flags: Int
    let ttl: Int
    let body: Data
}
private func records(_ packet: Data) -> [Record] {
    let bytes = [UInt8](packet)
    var offset = 0
    func integer(_ count: Int) -> Int {
        precondition(offset + count <= bytes.count)
        defer { offset += count }
        return bytes[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
    }
    func name() -> String {
        var labels: [String] = []
        while true {
            let size = integer(1)
            if size == 0 { break }
            precondition(size <= 63 && offset + size <= bytes.count)
            labels.append(String(bytes: bytes[offset..<offset + size], encoding: .utf8)!)
            offset += size
        }
        return labels.joined(separator: ".") + "."
    }
    precondition(integer(2) == 0 && integer(2) == 0x8400 && integer(2) == 0)
    let count = integer(2)
    precondition(integer(2) == 0 && integer(2) == 0)
    var result: [Record] = []
    for _ in 0..<count {
        let owner = name(), type = integer(2), flags = integer(2), ttl = integer(4), size = integer(2)
        precondition(offset + size <= bytes.count)
        result.append(Record(name: owner, type: type, flags: flags, ttl: ttl, body: Data(bytes[offset..<offset + size])))
        offset += size
    }
    precondition(offset == bytes.count)
    return result
}
private func txt(_ data: Data) -> [String: String] {
    let bytes = [UInt8](data)
    var offset = 0
    var result: [String: String] = [:]
    while offset < bytes.count {
        let size = Int(bytes[offset]); offset += 1
        precondition(offset + size <= bytes.count)
        let text = String(bytes: bytes[offset..<offset + size], encoding: .utf8)!
        let pieces = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        precondition(pieces.count == 2)
        result[String(pieces[0])] = String(pieces[1]); offset += size
    }
    return result
}

private final class FakeIO {
    var now: TimeInterval = 0
    var links: [AWDLAdvertisement.Link] = []
    var nextFD: Int32 = 40
    var opened: [(Int32, AWDLAdvertisement.Link)] = []
    var closed: [Int32] = []
    var sent: [(Int32, AWDLAdvertisement.Link, Data)] = []
    var statuses: [AWDLAdvertisement.Status] = []
    var failures = 0
    var openAttempts = 0
    var failOpen = false
    var failSend = false
    var operations: AWDLAdvertisement.Operations {
        .init(links: { self.links }, open: { link in
            self.openAttempts += 1
            if self.failOpen { throw POSIXError(.EACCES) }
            let fd = self.nextFD; self.nextFD += 1
            self.opened.append((fd, link)); return fd
        }, send: { fd, link, packet in
            precondition(!self.closed.contains(fd), "Send after descriptor close")
            if self.failSend { throw POSIXError(.EAGAIN) }
            self.sent.append((fd, link, packet))
        }, close: { fd in
            precondition(!self.closed.contains(fd), "Descriptor closed twice")
            self.closed.append(fd)
        }, clock: { self.now })
    }
    func core(_ snapshot: MDNSAnnouncement) -> AWDLAdvertisement.Core {
        .init(snapshot: snapshot, operations: operations, changed: { self.statuses.append($0) }, failed: { _ in self.failures += 1 })
    }
}

@main struct AWDLAdvertisementChecks {
    static func snapshot(name: String = "Studio", port: UInt16 = 19001) throws -> MDNSAnnouncement {
        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        return try MDNSAnnouncement(serverID: id,
            txt: ["sid": id, "at": String(repeating: "a", count: 64), "sn": "com.apple.sharingd.AirDrop", "dnm": name],
            services: [.init(type: "_appSvcPrePair._tcp", port: port), .init(type: "_applicationServicePairing._tcp", port: 19002)])
    }
    static func main() throws {
        let a = AWDLAdvertisement.Link(index: 17, address: Data([0xfe, 0x80] + Array(repeating: 0, count: 13) + [1]))
        let b = AWDLAdvertisement.Link(index: 17, address: Data([0xfe, 0x80] + Array(repeating: 0, count: 13) + [2]))
        let small = try snapshot()
        let encoded = try small.packets(address: a.address)
        precondition(encoded.count == 1)
        let parsed = records(encoded[0])
        precondition(parsed.count == 7 && parsed.allSatisfy { $0.ttl == 6 })
        precondition(parsed.filter { $0.type == 12 }.allSatisfy { $0.flags == 1 })
        precondition(parsed.filter { $0.type != 12 }.allSatisfy { $0.flags == 0x8001 })
        precondition(parsed.filter { $0.type == 16 }.allSatisfy { txt($0.body) == small.txt })
        precondition(Set(parsed.filter { $0.type == 33 }.map { Int($0.body[4]) << 8 | Int($0.body[5]) }) == [19001, 19002])
        precondition(parsed.first { $0.type == 28 }!.body == a.address)
        let long = try snapshot(name: String(repeating: "ą", count: 64))
        let split = try long.packets(address: a.address)
        precondition(split.count == 2 && split.allSatisfy { $0.count <= 1232 })
        for packet in split {
            let parts = records(packet)
            precondition(Set(parts.map(\.type)) == [12, 16, 28, 33])
            precondition(txt(parts.first { $0.type == 16 }!.body)["dnm"] == String(repeating: "ą", count: 64))
        }
        let expired = try small.packets(address: a.address, ttl: 0).flatMap(records)
        precondition(expired.allSatisfy { $0.ttl == 0 })
        do { _ = try snapshot(name: String(repeating: "x", count: 256)); preconditionFailure("Oversized TXT accepted") }
        catch MDNSAnnouncement.Invalid.record {}
        do { _ = try small.packets(address: Data([1, 2])); preconditionFailure("Invalid IPv6 accepted") }
        catch MDNSAnnouncement.Invalid.record {}

        let io = FakeIO()
        let publisher = io.core(small)
        publisher.tick()
        precondition(io.statuses == [.waiting] && io.opened.isEmpty)
        io.links = [a]; io.now = 1; publisher.tick()
        precondition(io.statuses == [.waiting, .advertising] && io.opened.count == 1)
        io.now = 2; publisher.tick()
        precondition(io.opened.count == 1 && io.sent.count == 2)
        let changed = try snapshot(name: "New name", port: 22001)
        publisher.replace(changed)
        precondition(io.closed == [40] && io.opened.count == 2)
        precondition(records(io.sent[2].2).allSatisfy { $0.ttl == 0 })
        precondition(txt(records(io.sent.last!.2).first { $0.type == 16 }!.body)["dnm"] == "New name")
        io.links = [b]; io.now = 3; publisher.tick()
        precondition(io.opened.count == 3 && io.opened.last!.1 == b)
        precondition(records(io.sent.last!.2).first { $0.type == 28 }!.body == b.address)
        io.links = []; io.now = 4; publisher.tick()
        precondition(io.statuses.last == .waiting && io.closed.count == 3)
        io.links = [AWDLAdvertisement.Link(index: 25, address: b.address)]
        io.now = 5; publisher.tick()
        precondition(io.opened.last!.1.index == 25)
        let beforeWake = io.opened.count
        io.now = 100; publisher.tick()
        precondition(io.opened.count == beforeWake + 1, "Wake must refresh the socket even with the same address")
        publisher.stop()
        let finalCount = io.sent.count
        precondition(records(io.sent.last!.2).allSatisfy { $0.ttl == 0 })
        publisher.stop(); publisher.replace(small); io.now = 200; publisher.tick()
        precondition(io.sent.count == finalCount && io.closed.count == io.opened.count)

        let denied = FakeIO()
        denied.links = [a]; denied.failOpen = true
        let retry = denied.core(small)
        retry.tick(); retry.tick()
        precondition(denied.openAttempts == 1 && denied.statuses == [.retrying])
        denied.now = 0.5; retry.tick(); precondition(denied.openAttempts == 1)
        denied.now = 1; retry.tick(); precondition(denied.openAttempts == 2)
        denied.now = 2; retry.tick(); precondition(denied.openAttempts == 2)
        denied.now = 3; retry.tick(); precondition(denied.openAttempts == 3)
        denied.now = 7; retry.tick(); precondition(denied.openAttempts == 4)
        denied.failOpen = false; denied.now = 11; retry.tick(); precondition(denied.opened.isEmpty)
        denied.now = 12; retry.tick(); precondition(denied.opened.count == 1 && denied.statuses.last == .advertising)
        denied.failSend = true; denied.now = 13; retry.tick()
        precondition(denied.closed.count == 1 && denied.statuses.last == .retrying)
        denied.failSend = false; denied.now = 13.5; retry.tick(); precondition(denied.opened.count == 1)
        denied.now = 14; retry.tick(); precondition(denied.opened.count == 2 && denied.opened[0].0 != denied.opened[1].0)
        retry.stop()
        print("PASS: DNS wire records/UTF-8/split/goodbye; interface loss/address/index/wake; bounded retry/fresh-socket recovery; terminal cleanup")
    }
}
