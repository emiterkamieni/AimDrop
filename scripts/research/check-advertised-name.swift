// Read-only verification of AimDrop's own Bonjour records after live rename.
import Foundation
import Network

@main struct CheckAdvertisedName {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let expected = CommandLine.arguments[1]
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_appSvcPrePair._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint, name.hasPrefix("AimDrop-"),
                      case .bonjour(let txt) = result.metadata, txt["dnm"] == expected else { continue }
                print("airfolder_advertised_name_matches_settings=yes")
                browser.cancel(); exit(0)
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("airfolder_advertised_name_matches_settings=not-found"); exit(1) }
        dispatchMain()
    }
}
