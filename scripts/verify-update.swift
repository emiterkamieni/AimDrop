// Verify release artifacts with public data only; no Keychain access.
import Foundation
import CryptoKit

final class EnclosureParser: NSObject, XMLParserDelegate {
    let filename: String
    var matches: [[String: String]] = []
    init(filename: String) { self.filename = filename }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure", let url = attributeDict["url"].flatMap(URL.init(string:)),
           url.lastPathComponent == filename { matches.append(attributeDict) }
    }
}

func fail(_ message: String) -> Never {
    fputs("Update verification failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("Expected ZIP path, appcast path and public Ed25519 key") }
let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
let feedURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let publicBytes = Data(base64Encoded: CommandLine.arguments[3]) else { fail("Invalid public key") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let feed = try Data(contentsOf: feedURL)
guard let text = String(data: feed, encoding: .utf8) else { fail("Invalid appcast encoding") }
let pattern = #"<!-- sparkle-signatures:\s*edSignature: (\S+)\s*length: ([0-9]+)\s*-->\s*$"#
let regex = try NSRegularExpression(pattern: pattern)
guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let signatureRange = Range(match.range(at: 1), in: text),
      let lengthRange = Range(match.range(at: 2), in: text),
      let footerRange = Range(match.range, in: text),
      let feedSignature = Data(base64Encoded: String(text[signatureRange])),
      let length = Int(text[lengthRange]), length > 0,
      length == text[..<footerRange.lowerBound].utf8.count,
      key.isValidSignature(feedSignature, for: feed.prefix(length)) else { fail("Invalid appcast signature") }
let delegate = EnclosureParser(filename: archiveURL.lastPathComponent)
let parser = XMLParser(data: feed)
parser.shouldResolveExternalEntities = false
parser.delegate = delegate
guard parser.parse(), delegate.matches.count == 1, let enclosure = delegate.matches.first,
      let encodedSignature = enclosure["sparkle:edSignature"], let signature = Data(base64Encoded: encodedSignature),
      let encodedLength = enclosure["length"], let expectedLength = Int(encodedLength) else { fail("Missing or ambiguous archive enclosure") }
let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
guard archive.count == expectedLength, key.isValidSignature(signature, for: archive) else { fail("Invalid archive signature or length") }
print("PASS: archive and appcast Ed25519 signatures verified with the public key only")
