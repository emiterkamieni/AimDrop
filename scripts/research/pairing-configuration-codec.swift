// Research-only: exercise the system's Codable implementation with synthetic data.
// No listener, account access, or remote communication.
import Foundation
import Network
import Darwin

enum ProbeError: Error {
    case unavailableType, notEncodable, changedConfiguration, unexpectedImageField
}

func verifyConfiguration() throws {
    let name = "7Network10NWListenerC7ServiceV20PairingConfigurationV"
    guard dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY | RTLD_LOCAL) != nil,
          let type = _typeByName(name) as? any Decodable.Type else {
        throw ProbeError.unavailableType
    }
    let input = Data("""
    {"supportedPairingTypes":[{"pin":{}}],"generatePairingValueImmediately":false,"_advertiseSensitiveInfo":false}
    """.utf8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    func roundTrip(_ data: Data) throws -> Data {
        let decoded = try JSONDecoder().decode(type, from: data)
        guard let encodable = decoded as? any Encodable else {
            throw ProbeError.notEncodable
        }
        return try encoder.encode(encodable)
    }

    let output = try roundTrip(input)
    let expected = try JSONSerialization.jsonObject(with: input) as! NSDictionary
    let actual = try JSONSerialization.jsonObject(with: output) as! NSDictionary
    guard expected == actual else { throw ProbeError.changedConfiguration }
    print(String(decoding: output, as: UTF8.self))
    print("native_pairing_configuration_round_trip=ok")

    // Confirm that an invented image field does not become part of this API.
    var withImage = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    withImage["contactImageData"] = Data("AIRFOLDER-PROBE".utf8).base64EncodedString()
    let imageOutput = try roundTrip(JSONSerialization.data(withJSONObject: withImage))
    guard imageOutput == output else { throw ProbeError.unexpectedImageField }
    print("contactImageData_in_listener_configuration=ignored")

    // The public property name differs from its actual Codable key.
    var wrongKey = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    wrongKey["_advertiseSensitiveInfo"] = nil
    wrongKey["advertiseSensitiveInfo"] = false
    do {
        _ = try roundTrip(JSONSerialization.data(withJSONObject: wrongKey))
        throw ProbeError.changedConfiguration
    } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "_advertiseSensitiveInfo" {
        print("incorrect_advertiseSensitiveInfo_key=rejected")
    }
}

do {
    try verifyConfiguration()
} catch {
    print("native_pairing_configuration_error=\(error)")
    exit(1)
}
