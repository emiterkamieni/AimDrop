import Foundation
import Darwin

/// AWDL-only announcements, deliberately outside the local Bonjour registry.
/// Complete records repeat once per second; no untrusted DNS parser is needed.
final class AWDLAdvertisement: @unchecked Sendable {
    struct Link: Equatable, Sendable {
        let index: UInt32
        let address: Data
    }
    enum Status: String { case advertising, waiting, retrying }
    struct Operations {
        var links: () -> [Link]
        var open: (Link) throws -> Int32
        var send: (Int32, Link, Data) throws -> Void
        var close: (Int32) -> Void
        var clock: () -> TimeInterval
    }

    /// Queue-confined lifecycle, also exercised offline with real encoded packets.
    final class Core {
        private let operations: Operations
        private let changed: (Status) -> Void
        private let failed: (Error) -> Void
        private var snapshot: MDNSAnnouncement
        private var socket: Int32?
        private var link: Link?
        private var selectedLink: Link?
        private var packets: [Data] = []
        private var goodbye: [Data] = []
        private var published = false
        private var stopped = false
        private var status: Status?
        private var retryAt: TimeInterval = 0
        private var retryDelay: TimeInterval = 1
        private var lastTick: TimeInterval?

        init(snapshot: MDNSAnnouncement, operations: Operations, changed: @escaping (Status) -> Void,
             failed: @escaping (Error) -> Void) {
            self.snapshot = snapshot; self.operations = operations
            self.changed = changed; self.failed = failed
        }
        func replace(_ value: MDNSAnnouncement) {
            guard !stopped, snapshot != value else { return }
            withdraw()
            snapshot = value
            retryAt = 0; retryDelay = 1
            tick()
        }
        func tick() {
            guard !stopped else { return }
            let now = operations.clock()
            let gap = lastTick.map { now - $0 > 5 } ?? false
            lastTick = now
            let links = operations.links().filter { $0.index > 0 && $0.address.count == 16 }
            let selected = links.first(where: { $0 == selectedLink }) ?? links.first
            if selected != selectedLink || gap {
                withdraw()
                selectedLink = selected
                retryAt = 0; retryDelay = 1
            }
            guard let selected else { report(.waiting); return }
            guard now >= retryAt else { return }
            do {
                if socket == nil {
                    let encoded = try snapshot.packets(address: selected.address)
                    let expired = try snapshot.packets(address: selected.address, ttl: 0)
                    socket = try operations.open(selected)
                    link = selected; packets = encoded; goodbye = expired
                }
                guard let socket else { return }
                for packet in packets {
                    try operations.send(socket, selected, packet)
                    published = true
                }
                retryDelay = 1
                report(.advertising)
            } catch {
                // An OS-accepted datagram is not proof of remote visibility.
                // In particular a denied socket can queue a few packets first.
                // Always discard it on failure, including after permission grants.
                closeSocket()
                retryAt = now + retryDelay
                retryDelay = min(retryDelay * 2, 5)
                if status != .retrying { failed(error) }
                report(.retrying)
            }
        }
        func stop() {
            guard !stopped else { return }
            stopped = true
            withdraw()
        }
        private func report(_ value: Status) {
            guard status != value else { return }
            status = value; changed(value)
        }
        private func withdraw() {
            if published, let socket, let link {
                for packet in goodbye { try? operations.send(socket, link, packet) }
            }
            closeSocket()
        }
        private func closeSocket() {
            if let socket { operations.close(socket) }
            socket = nil; link = nil; published = false
            packets.removeAll(); goodbye.removeAll()
        }
    }

    private let queue = DispatchQueue(label: "pl.aimdrop.awdl-advertisement")
    private let queueKey = DispatchSpecificKey<Void>()
    private let core: Core
    private var timer: DispatchSourceTimer?
    private var stopped = false
    init(snapshot: MDNSAnnouncement, changed: @escaping @Sendable (Status) -> Void) {
        core = Core(snapshot: snapshot, operations: Self.systemOperations, changed: changed, failed: { error in
            let code = (error as? POSIXError)?.code.rawValue ?? 0
            print("awdl_advertisement_retry errno=\(code)")
        })
        queue.setSpecific(key: queueKey, value: ())
    }
    func start() {
        queue.sync {
            guard timer == nil, !stopped else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.core.tick() }
            timer = source
            source.resume()
        }
    }
    func replace(_ snapshot: MDNSAnnouncement) { queue.sync { core.replace(snapshot) } }
    func stop() {
        let action = {
            guard !self.stopped else { return }
            self.stopped = true
            self.timer?.cancel(); self.timer = nil
            self.core.stop()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { action() }
        else { queue.sync(execute: action) }
    }
    deinit { stop() }

    private static let timeScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static var continuousTime: TimeInterval { Double(mach_continuous_time()) * timeScale }
    private static var systemOperations: Operations {
        Operations(links: activeLinks, open: openSocket, send: sendPacket,
                   close: { _ = Darwin.close($0) }, clock: { continuousTime })
    }
    private static func activeLinks() -> [Link] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [Link] = []
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let value = current.pointee
            guard String(cString: value.ifa_name) == "awdl0", value.ifa_flags & UInt32(IFF_UP) != 0,
                  let pointer = value.ifa_addr, Int32(pointer.pointee.sa_family) == AF_INET6 else { continue }
            var raw = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var address = withUnsafeBytes(of: &raw) { Data($0) }
            guard address[0] == 0xfe && address[1] & 0xc0 == 0x80 else { continue }
            // Darwin may embed a link-local scope in bytes 2–3. DNS AAAA must not.
            address[2] = 0; address[3] = 0
            let index = if_nametoindex(value.ifa_name)
            if index > 0 { result.append(Link(index: index, address: address)) }
        }
        return result.sorted { $0.address.lexicographicallyPrecedes($1.address) }
    }
    private static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func endpoint(_ link: Link, multicast: Bool) -> sockaddr_in6 {
        var result = sockaddr_in6()
        result.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        result.sin6_family = sa_family_t(AF_INET6)
        result.sin6_port = UInt16(5353).bigEndian
        result.sin6_scope_id = link.index
        if multicast { inet_pton(AF_INET6, "ff02::fb", &result.sin6_addr) }
        else { withUnsafeMutableBytes(of: &result.sin6_addr) { $0.copyBytes(from: link.address) } }
        return result
    }
    private static func withAddress<T>(_ value: inout sockaddr_in6, _ action: (UnsafePointer<sockaddr>) -> T) -> T {
        withUnsafePointer(to: &value) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1, action) }
    }
    private static func openSocket(_ link: Link) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw error() }
        do {
            var enabled: Int32 = 1
            var disabled: UInt32 = 0
            var index = link.index
            var hops: Int32 = 255
            // Darwin's SO_RECV_ANYIF includes interfaces such as AWDL. All
            // transmission is additionally scoped/bound to the selected AWDL link.
            let receiveAnyInterface: Int32 = 0x1104
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, 4) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &enabled, 4) == 0,
                  setsockopt(fd, SOL_SOCKET, receiveAnyInterface, &enabled, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, 4) == 0,
                  setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &disabled, 4) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw error() }
            var local = endpoint(link, multicast: false)
            guard withAddress(&local, { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else { throw error() }
            // A connected UDP sender only matches traffic from its multicast
            // destination. It must not consume peers' unicast DNS questions
            // that belong to mDNSResponder on this same source port.
            var target = endpoint(link, multicast: true)
            guard withAddress(&target, { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else { throw error() }
            return fd
        } catch { _ = Darwin.close(fd); throw error }
    }
    private static func sendPacket(_ fd: Int32, _: Link, _ packet: Data) throws {
        let sent = packet.withUnsafeBytes { bytes in
            Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == packet.count else { throw sent < 0 ? error() : POSIXError(.EIO) }
    }
}
