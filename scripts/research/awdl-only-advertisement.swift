// Research-only external announcements. Full records repeat every second, so
// this bounded prototype does not yet implement query/known-answer handling.
// It is deliberately excluded from the production helper's source list.
import Foundation
import Network
import Darwin

final class AWDLOnlyAdvertisement: @unchecked Sendable {
    struct Service {
        let name: String
        let type: String
        let port: UInt16
        let txt: [String: String]
    }
    private let queue = DispatchQueue(label: "pl.aimdrop.awdl-advertisement-probe")
    private let fd: Int32
    private let index: UInt32
    private let packet: Data
    private let goodbye: Data
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var announced = false
    private let services: [Service]
    private let verifyLocally: Bool
    private var observers: [NWBrowser] = []
    private var observedTypes = Set<String>()

    init(services: [Service], host: String, multicastLoopback: Bool = false, verifyLocally: Bool = false) throws {
        guard !services.isEmpty, let (index, address) = Self.localAddress() else {
            throw ProbeError.stage("AWDL link-local address unavailable")
        }
        self.index = index
        self.services = services
        self.verifyLocally = verifyLocally
        packet = try Self.response(services, host: host, address: address, ttl: 6)
        goodbye = try Self.response(services, host: host, address: address, ttl: 0)
        fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ProbeError.stage("AWDL multicast socket unavailable") }
        do {
            var enabled: Int32 = 1
            var loopback: UInt32 = multicastLoopback ? 1 : 0
            var hops: Int32 = 255
            var required = index
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, 4) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &enabled, 4) == 0,
                  setsockopt(fd, SOL_SOCKET, 0x1104, &enabled, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &required, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &loopback, 4) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw ProbeError.stage("AWDL multicast options unavailable")
            }
            var local = Self.endpoint(address: address, index: index)
            guard Self.withAddress(&local, { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else {
                throw ProbeError.stage("AWDL multicast bind failed")
            }
        } catch { close(fd); throw error }
    }

    func start() {
        queue.sync {
            guard timer == nil, !stopped else { return }
            if verifyLocally {
                for service in services {
                    let parameters = NWParameters()
                    parameters.includePeerToPeer = true
                    let observer = NWBrowser(for: .bonjourWithTXTRecord(type: service.type, domain: "local."), using: parameters)
                    observer.browseResultsChangedHandler = { [weak self] results, _ in
                        guard let self, !self.stopped else { return }
                        for result in results {
                            if case .service(let name, _, _, _) = result.endpoint, name == service.name,
                               self.observedTypes.insert(service.type).inserted {
                                print("awdl_external_locally_seen type=\(service.type)")
                            }
                        }
                    }
                    observer.start(queue: queue)
                    observers.append(observer)
                }
            }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1)
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let result = self.send(self.packet)
                if result >= 0, !self.announced {
                    self.announced = true
                    print("awdl_external_announcement_sent bytes=\(result)")
                } else if result < 0 {
                    print("awdl_external_announcement_failed errno=\(errno)")
                }
            }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            if verifyLocally { print("awdl_external_local_types=\(observedTypes.count)") }
            observers.forEach { $0.cancel() }; observers.removeAll()
            timer?.cancel(); timer = nil
            _ = send(goodbye)
            close(fd)
        }
    }
    deinit { stop() }

    private func send(_ data: Data) -> Int {
        var multicast = in6_addr()
        inet_pton(AF_INET6, "ff02::fb", &multicast)
        var target = Self.endpoint(address: multicast, index: index)
        return data.withUnsafeBytes { bytes in
            Self.withAddress(&target) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    private static func endpoint(address: in6_addr, index: UInt32) -> sockaddr_in6 {
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = UInt16(5353).bigEndian
        value.sin6_scope_id = index
        value.sin6_addr = address
        return value
    }
    private static func withAddress<T>(_ address: inout sockaddr_in6, _ body: (UnsafePointer<sockaddr>) -> T) -> T {
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
    }
    private static func localAddress() -> (UInt32, in6_addr)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let value = current.pointee
            guard String(cString: value.ifa_name) == "awdl0",
                  let pointer = value.ifa_addr, Int32(pointer.pointee.sa_family) == AF_INET6 else { continue }
            var address = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard withUnsafeBytes(of: &address, { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }) else { continue }
            withUnsafeMutableBytes(of: &address) { $0[2] = 0; $0[3] = 0 }
            return (if_nametoindex(value.ifa_name), address)
        }
        return nil
    }
    private static func integer<T: FixedWidthInteger>(_ number: T) -> Data {
        var value = number.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private static func name(_ value: String) throws -> Data {
        var result = Data()
        for label in value.split(separator: ".") {
            let bytes = Data(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { throw ProbeError.invalidArgument }
            result.append(UInt8(bytes.count)); result.append(bytes)
        }
        result.append(0)
        guard result.count <= 255 else { throw ProbeError.invalidArgument }
        return result
    }
    private static func record(_ owner: String, type: UInt16, value: Data, ttl: UInt32, unique: Bool = false) throws -> Data {
        try name(owner) + integer(type) + integer(UInt16(unique ? 0x8001 : 1))
            + integer(ttl) + integer(UInt16(value.count)) + value
    }
    private static func response(_ services: [Service], host: String, address: in6_addr, ttl: UInt32) throws -> Data {
        var records = Data()
        for service in services {
            let type = service.type + ".local."
            let fullName = service.name + "." + type
            var txt = Data()
            for key in service.txt.keys.sorted() {
                let item = Data((key + "=" + service.txt[key]!).utf8)
                guard item.count <= 255 else { throw ProbeError.invalidArgument }
                txt.append(UInt8(item.count)); txt.append(item)
            }
            records.append(try record(type, type: 12, value: name(fullName), ttl: ttl))
            records.append(try record(fullName, type: 33, value: integer(UInt16(0)) + integer(UInt16(0))
                + integer(service.port) + name(host), ttl: ttl, unique: true))
            records.append(try record(fullName, type: 16, value: txt, ttl: ttl, unique: true))
        }
        var address = address
        records.append(try record(host, type: 28, value: withUnsafeBytes(of: &address) { Data($0) }, ttl: ttl, unique: true))
        let packet = integer(UInt16(0)) + integer(UInt16(0x8400)) + integer(UInt16(0))
            + integer(UInt16(services.count * 3 + 1)) + integer(UInt16(0)) + integer(UInt16(0)) + records
        guard packet.count <= 1400 else { throw ProbeError.stage("AWDL advertisement exceeds prototype packet limit") }
        return packet
    }
}
