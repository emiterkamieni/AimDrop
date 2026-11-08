// Observe only synthetic test services; never initiate pairing or connections.
import Foundation
import Network

@main struct SelfDiscoveryObserver {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        setbuf(stdout, nil)
        let prefix = CommandLine.arguments[1]
        guard prefix.hasPrefix("ADProbe-") || (prefix.hasPrefix("AimDrop-")
            && UUID(uuidString: String(prefix.dropFirst("AimDrop-".count))) != nil) else { exit(2) }
        let queue = DispatchQueue(label: "pl.aimdrop.self-discovery-observer")
        var browsers: [NWBrowser] = []
        var seen = Set<String>()
        for type in ["_appSvcPrePair._tcp", "_applicationServicePairing._tcp"] {
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint,
                          name.hasPrefix(prefix) else { continue }
                    guard seen.insert(name + " " + type).inserted else { continue }
                    print("seen name=\(name) type=\(type) interfaces=\(result.interfaces.map(\.name).sorted().joined(separator: ","))")
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("observer_failed=\(error)") }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        print("observer_started")
        let done = DispatchSemaphore(value: 0)
        queue.asyncAfter(deadline: .now() + 12) {
            print("summary observed=\(seen.count)")
            browsers.forEach { $0.cancel() }
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else { exit(2) }
        queue.sync {}
    }
}
