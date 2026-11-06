import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

@main struct AvatarChecks {
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
    static func image(_ data: Data) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    }
    static func encode(_ image: CGImage, type: String, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let output = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(output))
        return data as Data
    }
    static func incompletePNG() -> Data {
        func integer(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        func chunk(_ name: String, _ payload: Data) -> Data {
            let body = Data(name.utf8) + payload
            let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)) }
            return integer(UInt32(payload.count)) + body + integer(UInt32(crc))
        }
        let raw = Data(repeating: 0, count: (1 + 256 * 4) * 128) // IHDR promises 256 rows
        var size = compressBound(uLong(raw.count))
        var packed = Data(count: Int(size))
        let status = packed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &size,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), Z_BEST_SPEED)
            }
        }
        precondition(status == Z_OK)
        packed.count = Int(size)
        return Data([137, 80, 78, 71, 13, 10, 26, 10])
            + chunk("IHDR", integer(256) + integer(256) + Data([8, 6, 0, 0, 0]))
            + chunk("IDAT", packed) + chunk("IEND", Data())
    }
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1)); context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        let landscape = context.makeImage()!
        var crop = AvatarCrop(image: landscape)
        let centered = try crop.avatar()
        precondition(pixel(image(centered.png), x: 10, y: 128)[0] > 240)
        precondition(pixel(image(centered.png), x: 245, y: 128)[2] > 240)
        crop.move(dx: 100, dy: -100)
        let shifted = try crop.avatar()
        precondition(pixel(image(shifted.png), x: 128, y: 128)[0] > 240, "Drag right must reveal the image's left side")
        crop.setZoom(100); crop.move(dx: -100, dy: 100)
        precondition(crop.zoom == 4)
        let zoomed = image(try crop.avatar().png)
        for point in [(0, 0), (255, 0), (0, 255), (255, 255)] {
            precondition(pixel(zoomed, x: point.0, y: point.1)[3] == 255, "Crop must stay covered at extreme pan/zoom")
        }
        crop.setZoom(0)
        precondition(crop.zoom == 1 && crop.offset.y == 0)

        let source = temp.appendingPathComponent("source.jpg")
        try encode(landscape, type: UTType.jpeg.identifier, properties: [kCGImagePropertyOrientation: 6]).write(to: source)
        let oriented = try ReceiverAvatar.source(at: source)
        precondition(oriented.width == 200 && oriented.height == 400, "EXIF rotation must apply before cropping")
        try FileManager.default.removeItem(at: source)
        _ = try AvatarCrop(image: oriented).avatar() // decoded crop survives deletion
        try encode(landscape, type: UTType.jpeg.identifier, properties: [kCGImagePropertyOrientation: 2]).write(to: source)
        let mirrored = try ReceiverAvatar.source(at: source)
        precondition(pixel(mirrored, x: 10, y: 100)[2] > 200, "Mirrored EXIF orientation must be applied")

        let metadata = encode(image(centered.png), type: UTType.png.identifier,
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "same picture, different metadata"]])
        let alternate = try ReceiverAvatar(png: metadata)
        precondition(alternate.digest == centered.digest, "Metadata must not change pairing identity")
        L10n.configure(.english)
        precondition(AvatarError.invalidImage.localizedDescription.hasPrefix("Cannot read this image."))
        L10n.configure(.polish)
        precondition(AvatarError.invalidImage.localizedDescription.hasPrefix("Nie można odczytać tego obrazu."))
        let relocalized = try ReceiverAvatar(png: centered.png)
        precondition(relocalized.digest == centered.digest && relocalized.png == centered.png,
                     "Changing language must never change the avatar fingerprint or raster")
        let baseline = try ReceiverAvatar.defaultLogo(at: URL(fileURLWithPath: CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : ".build/artwork/AimDropAvatar.png"))
        // ImageIO may return a CGImage for a truncated IDAT and silently draw
        // transparent pixels. It must not become a new valid pairing avatar.
        var offset = 8
        var truncated = Data()
        while offset + 12 <= baseline.png.count {
            let length = baseline.png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            if String(data: baseline.png[(offset + 4)..<(offset + 8)], encoding: .ascii) == "IDAT" {
                truncated = Data(baseline.png.prefix(offset + 8 + max(1, length / 2)))
                break
            }
            offset += length + 12
        }
        precondition(!truncated.isEmpty)
        let location = try centered.materialize(in: temp.appendingPathComponent("Avatars"))
        try FileManager.default.removeItem(at: location)
        let restored = try centered.materialize(in: temp.appendingPathComponent("Avatars"))
        let restoredData = try Data(contentsOf: restored)
        let restoredAvatar = try ReceiverAvatar.read(at: restored)
        precondition(restoredData == centered.png && restoredAvatar.digest == centered.digest)
        let incomplete = incompletePNG()
        for invalid in [Data("bad image".utf8), encode(landscape, type: UTType.png.identifier), truncated, incomplete] {
            do { _ = try ReceiverAvatar(png: invalid); fatalError("Invalid avatar accepted") }
            catch is AvatarError { }
        }
        if (2...3).contains(CommandLine.arguments.count) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try centered.png.write(to: directory.appendingPathComponent("avatar.png"))
            try metadata.write(to: directory.appendingPathComponent("same-image.png"))
            try truncated.write(to: directory.appendingPathComponent("truncated.png"))
            try incomplete.write(to: directory.appendingPathComponent("short-scanlines.png"))
            try JSONSerialization.data(withJSONObject: ["avatar_digest": centered.digest, "default_digest": baseline.digest])
                .write(to: directory.appendingPathComponent("digests.json"))
        }
        print("PASS: pan direction, coverage/zoom limits, EXIF rotation/mirroring, source deletion, PNG validation, metadata-independent fingerprint, durable avatar reconstruction")
    }
}
