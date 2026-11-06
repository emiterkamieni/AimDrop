// Earlier static-credential loopback proof of native distributed identity exchange.
import Foundation
import Network
import Distributed
import Darwin
import CryptoKit

private let probePIN = "471582"

func parameters(server: Bool, wrongPIN: Bool = false) throws -> NWParameters {
    guard let identity = AFCreateSPAKEIdentity("airfolder-loopback", "probe-client", "probe-server", wrongPIN ? "000000" : probePIN, server) else {
        throw NSError(domain: "Probe", code: 3)
    }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 5
    let parameters = NWParameters(tls: tls, tcp: tcp)
    if server { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
    return parameters
}

struct RPPairingTemporaryIdentity: Codable, Equatable {
    var contactIdentifier: String?
    var contactImageData: Data?
    var dateAdded: Date
    var deviceName: String
    var identifier: String
    var givenName: String
    var familyName: String
    var deviceIRKData: Data
    var devicePublicKey: Data
}

distributed actor RPPairingDistributedActor: NWSingletonPublishedActor {
    typealias ActorSystem = NWActorSystem
    let identity: RPPairingTemporaryIdentity

    init(identity: RPPairingTemporaryIdentity, actorSystem: NWActorSystem) {
        self.identity = identity
        self.actorSystem = actorSystem
    }

    distributed func pairAndReceiveTemporaryIdentities(pairingData: Data) async throws -> [RPPairingTemporaryIdentity]? {
        print("remote_identity_request=received")
        guard pairingData == Data(probePIN.utf8) else { return nil }
        return [identity]
    }
}

@main struct Probe {
    static func main() async {
        setbuf(stdout, nil)
        // Always bound execution, including failed native calls.
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { exit(8) }
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let image = try Data(contentsOf: URL(fileURLWithPath: ".build/artwork/AimDropAvatar.png"))
            if arguments.first == "--client", arguments.count >= 2, let rawPort = UInt16(arguments[1]), let port = NWEndpoint.Port(rawValue: rawPort) {
                let wrongPIN = arguments.contains("--wrong-pin")
                let parameters = try parameters(server: false, wrongPIN: wrongPIN)
                let client = NWActorSystem(parameters: parameters)
                let remote = try RPPairingDistributedActor.discover(.hostPort(host: .ipv4(.loopback), port: port), connectionParameters: parameters, using: client, invalidationHandler: nil)
                guard __isRemoteActor(remote) else { throw NSError(domain: "Probe", code: 4) }
                do {
                    let response = try await remote.pairAndReceiveTemporaryIdentities(pairingData: Data(probePIN.utf8))
                    if wrongPIN {
                        print("wrong_pin_unexpectedly_accepted")
                        exit(1)
                    }
                    guard let result = response?.first, result.contactImageData == image, result.deviceName == "AimDrop" else {
                        throw NSError(domain: "Probe", code: 5)
                    }
                    print("native_actor_spake_image_round_trip=ok bytes=\(image.count)")
                    exit(0)
                } catch {
                    if wrongPIN {
                        print("wrong_pin_rejected=\(error)")
                        exit(0)
                    }
                    throw error
                }
            }
            guard arguments == ["--server"] else { throw NSError(domain: "Probe", code: 6) }
            let server = NWActorSystem(service: NWListener.Service(name: "AimDrop Loopback", type: "_airfolderprobe._tcp"), parameters: try parameters(server: true))
            let privateKey = Curve25519.Signing.PrivateKey()
            var irk = Data(count: 16)
            let randomStatus = irk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard randomStatus == errSecSuccess else { throw NSError(domain: "Probe", code: 7) }
            let identity = RPPairingTemporaryIdentity(
                contactImageData: image, dateAdded: Date(), deviceName: "AimDrop",
                identifier: UUID().uuidString, givenName: "AimDrop", familyName: "",
                deviceIRKData: irk, devicePublicKey: privateKey.publicKey.rawRepresentation
            )
            let actor = RPPairingDistributedActor(identity: identity, actorSystem: server)
            try await server.publishAndWaitForReady(actor)
            guard let port = server.listener?.port else { throw NSError(domain: "Probe", code: 1) }
            print("loopback_server_ready port=\(port.rawValue)")
            try await Task.sleep(nanoseconds: 10_000_000_000)
            server.invalidateActor(actor)
            server.listener?.cancel()
            exit(0)
        } catch {
            print("native_actor_error=\(error)")
            exit(1)
        }
    }
}
