// Native, bounded multicast experiment. Run with xcrun swift; does not register
// Bonjour records, use real pairing identities, or connect to any receiver.
import Foundation
import Network
import Darwin

setbuf(stdout, nil)
guard CommandLine.arguments.count <= 3 else { exit(2) }
let selectedInterface = CommandLine.arguments.dropFirst().first
let duration = CommandLine.arguments.count == 3 ? Double(CommandLine.arguments[2]) ?? 10 : 10
guard (10...300).contains(duration) else { exit(2) }
let connectedSender = ProcessInfo.processInfo.environment["AIMDROP_PROBE_CONNECTED"] == "1"

func encodedName(_ value: String) -> Data {
    var result = Data()
    for label in value.split(separator: ".") {
        let bytes = Data(label.utf8)
        precondition(bytes.count <= 63)
        result.append(UInt8(bytes.count))
        result.append(bytes)
    }
    result.append(0)
    return result
}

func integer<T: FixedWidthInteger>(_ number: T) -> Data {
    var bigEndian = number.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

func record(_ owner: String, _ type: UInt16, _ value: Data, ttl: UInt32, unique: Bool = false) -> Data {
    encodedName(owner) + integer(type) + integer(UInt16(unique ? 0x8001 : 1))
        + integer(ttl) + integer(UInt16(value.count)) + value
}

let types = ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp"]
func response(_ instance: String, _ address: in6_addr, ttl: UInt32) -> Data {
    let host = instance.lowercased() + ".local."
    var records = Data()
    for type in types {
        let service = type + ".local."
        let fullName = instance + "." + service
        var txt = Data()
        for value in ["sn=pl.aimdrop.self-discovery-probe", "sid=" + instance] {
            let data = Data(value.utf8)
            txt.append(UInt8(data.count)); txt.append(data)
        }
        records.append(record(service, 12, encodedName(fullName), ttl: ttl))
        records.append(record(fullName, 33, integer(UInt16(0)) + integer(UInt16(0))
            + integer(UInt16(9)) + encodedName(host), ttl: ttl, unique: true))
        records.append(record(fullName, 16, txt, ttl: ttl, unique: true))
    }
    var address = address
    records.append(record(host, 28, withUnsafeBytes(of: &address) { Data($0) }, ttl: ttl, unique: true))
    return integer(UInt16(0)) + integer(UInt16(0x8400)) + integer(UInt16(0))
        + integer(UInt16(7)) + integer(UInt16(0)) + integer(UInt16(0)) + records
}

func withAddress<T>(_ address: inout sockaddr_in6, _ body: (UnsafePointer<sockaddr>) -> T) -> T {
    withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
}

struct Sender {
    let interface: String
    let index: UInt32
    let address: in6_addr
    let fd: Int32
    func send(_ data: Data, loop: Bool) {
        var enabled: UInt32 = loop ? 1 : 0
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &enabled, 4) == 0 else {
            print("option_failed interface=\(interface) errno=\(errno)"); return
        }
        var target = sockaddr_in6()
        target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = UInt16(5353).bigEndian
        target.sin6_scope_id = index
        inet_pton(AF_INET6, "ff02::fb", &target.sin6_addr)
        let result = data.withUnsafeBytes { bytes in
            if connectedSender { return Darwin.send(fd, bytes.baseAddress, bytes.count, 0) }
            return withAddress(&target) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        print("send interface=\(interface) loop=\(loop) bytes=\(result) errno=\(result < 0 ? errno : 0)")
    }
}

var senders: [Sender] = []
var interfaces: UnsafeMutablePointer<ifaddrs>?
guard getifaddrs(&interfaces) == 0 else { exit(2) }
var cursor = interfaces
while let item = cursor {
    defer { cursor = item.pointee.ifa_next }
    let value = item.pointee
    let label = String(cString: value.ifa_name)
    if let selectedInterface, selectedInterface != label { continue }
    guard label == "awdl0" || label.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
          value.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
          let address = value.ifa_addr, Int32(address.pointee.sa_family) == AF_INET6 else { continue }
    var local = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
    let linkLocal = withUnsafeBytes(of: &local.sin6_addr) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
    guard linkLocal else { continue }
    // Normalize Darwin's embedded link-local scope for DNS AAAA bytes.
    withUnsafeMutableBytes(of: &local.sin6_addr) { $0[2] = 0; $0[3] = 0 }
    var index = if_nametoindex(value.ifa_name)
    local.sin6_scope_id = index
    local.sin6_port = UInt16(5353).bigEndian
    let fd = socket(AF_INET6, SOCK_DGRAM, 0)
    guard fd >= 0 else { continue }
    var enabled: Int32 = 1
    var hops: Int32 = 255
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, 4)
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &enabled, 4)
    setsockopt(fd, SOL_SOCKET, 0x1104, &enabled, 4) // SO_RECV_ANYIF, including AWDL.
    setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, 4)
    setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, 4)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    guard withAddress(&local, { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else {
        print("bind_failed interface=\(label) errno=\(errno)"); close(fd); continue
    }
    if connectedSender {
        var target = local
        inet_pton(AF_INET6, "ff02::fb", &target.sin6_addr)
        guard withAddress(&target, { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else {
            print("connect_failed interface=\(label) errno=\(errno)"); close(fd); continue
        }
    }
    senders.append(Sender(interface: label, index: index, address: local.sin6_addr, fd: fd))
}
freeifaddrs(interfaces)
guard !senders.isEmpty else { print("no_multicast_interface"); exit(2) }

let prefix = "ADProbe-" + UUID().uuidString.prefix(8)
let queue = DispatchQueue(label: "pl.aimdrop.native-multicast-probe")
var browsers: [NWBrowser] = []
var seen = Set<String>()
for type in types {
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
    browser.browseResultsChangedHandler = { results, _ in
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name.hasPrefix(prefix),
                  seen.insert(name + " " + type).inserted else { continue }
            print("seen name=\(name) type=\(type) interfaces=\(result.interfaces.map(\.name))")
        }
    }
    browser.stateUpdateHandler = { state in
        if case .failed(let error) = state { print("browser_failed=\(error)") }
    }
    browser.start(queue: queue)
    browsers.append(browser)
}
for delay in stride(from: 1, through: Int(duration) - 2, by: 2) {
    queue.asyncAfter(deadline: .now() + Double(delay)) {
        for sender in senders {
            for loop in [true, false] {
                let instance = prefix + "-" + sender.interface + (loop ? "-loop" : "-remote")
                sender.send(response(instance, sender.address, ttl: 10), loop: loop)
            }
        }
    }
}
let done = DispatchSemaphore(value: 0)
var result: Int32 = 2
queue.asyncAfter(deadline: .now() + duration) {
    result = 1
    for sender in senders {
        let baseline = seen.filter { $0.contains("-" + sender.interface + "-loop ") }.count
        let remote = seen.filter { $0.contains("-" + sender.interface + "-remote ") }.count
        print("result interface=\(sender.interface) baseline_types=\(baseline) remote_only_types=\(remote)")
        if baseline == 2 { result = 0 }
        for loop in [true, false] {
            let instance = prefix + "-" + sender.interface + (loop ? "-loop" : "-remote")
            sender.send(response(instance, sender.address, ttl: 0), loop: loop)
        }
        close(sender.fd)
    }
    browsers.forEach { $0.cancel() }
    done.signal()
}
guard done.wait(timeout: .now() + duration + 5) == .success else { exit(2) }
queue.sync {}
exit(result)
