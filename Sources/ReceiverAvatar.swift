// Shared by AppKit and the headless receiver: preview, exported image and
// pairing fingerprint all describe the same 256px sRGB raster.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import zlib

enum AvatarError: LocalizedError {
    case invalidImage, missingDefault
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Nie można odczytać tego obrazu. Wybierz zdjęcie PNG, JPEG lub HEIC."
        case .missingDefault: return "Brak domyślnego awatara w zasobach AirFolder."
        }
    }
}

struct AvatarCrop {
    let image: CGImage
    private(set) var zoom: CGFloat = 1
    private(set) var offset = CGPoint.zero // fractions of the crop diameter

    mutating func setZoom(_ value: CGFloat) {
        zoom = min(4, max(1, value.isFinite ? value : 1))
        clamp()
    }
    mutating func move(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        offset.x += dx; offset.y += dy
        clamp()
    }
    private mutating func clamp() {
        let side = CGFloat(min(image.width, image.height))
        let x = (CGFloat(image.width) / side * zoom - 1) / 2
        let y = (CGFloat(image.height) / side * zoom - 1) / 2
        offset.x = min(x, max(-x, offset.x))
        offset.y = min(y, max(-y, offset.y))
    }
    func imageRect(in bounds: CGRect) -> CGRect {
        let side = min(bounds.width, bounds.height)
        let scale = side / CGFloat(min(image.width, image.height)) * zoom
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x * side,
                      y: bounds.midY - size.height / 2 + offset.y * side,
                      width: size.width, height: size.height)
    }
    func avatar() throws -> ReceiverAvatar {
        try ReceiverAvatar.render(image: image, rect: imageRect(in: CGRect(x: 0, y: 0, width: 256, height: 256)))
    }
}

struct ReceiverAvatar: Equatable {
    let png: Data
    let digest: String
    static let maximumPNGBytes = 512 * 1024

    init(png: Data) throws {
        guard png.count <= Self.maximumPNGBytes else { throw AvatarError.invalidImage }
        try Self.validatePNG(png, canonical: true)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 256,
              properties[kCGImagePropertyPixelHeight] as? Int == 256,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AvatarError.invalidImage }
        let context = try Self.context()
        context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw AvatarError.invalidImage }
        guard let pixels = context.data else { throw AvatarError.invalidImage }
        var fingerprint = Data("AirFolderAvatar-rgba8-srgb-256-v1\0".utf8)
        fingerprint.append(Data(bytes: pixels, count: 256 * 256 * 4))
        self.png = png
        digest = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }
    static func source(at url: URL, maximumSize: Int = 2048) throws -> CGImage {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw AvatarError.invalidImage }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { try validatePNG(Data(contentsOf: url)) }
        return image
    }
    static func defaultLogo(at url: URL) throws -> ReceiverAvatar {
        try AvatarCrop(image: source(at: url, maximumSize: 256)).avatar()
    }
    static func read(at url: URL) throws -> ReceiverAvatar {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumPNGBytes else { throw AvatarError.invalidImage }
        return try ReceiverAvatar(png: Data(contentsOf: url))
    }
    private static func validatePNG(_ data: Data, canonical: Bool = false) throws {
        // ImageIO can report "complete" even for an IDAT cut in half and draw
        // an empty image. Check chunk boundaries, CRCs and IEND independently.
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw AvatarError.invalidImage }
        func number(_ start: Int) -> UInt32 {
            data[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var offset = 8
        var compressed = Data()
        var rows: [(count: Int, bytes: Int)] = []
        while offset <= data.count - 12 {
            let length = Int(number(offset))
            guard length <= data.count - offset - 12 else { throw AvatarError.invalidImage }
            let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
            guard (offset == 8) == (type == "IHDR"), offset != 8 || length == 13 else { throw AvatarError.invalidImage }
            let chunk = data[(offset + 4)..<(offset + 8 + length)]
            let crc = chunk.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
            guard UInt32(crc) == number(offset + 8 + length) else { throw AvatarError.invalidImage }
            if type == "IHDR" {
                let width = Int(number(offset + 8)), height = Int(number(offset + 12))
                let depth = Int(data[offset + 16]), color = data[offset + 17], interlace = data[offset + 20]
                let channels: [UInt8: Int] = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4]
                let depths = color == 0 ? [1, 2, 4, 8, 16] : color == 3 ? [1, 2, 4, 8] : [8, 16]
                if canonical {
                    guard width == 256, height == 256, depth == 8, [2, 6].contains(color), interlace == 0 else { throw AvatarError.invalidImage }
                }
                guard width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 100_000_000,
                      let count = channels[color], depths.contains(depth), interlace <= 1,
                      data[offset + 18] == 0, data[offset + 19] == 0 else { throw AvatarError.invalidImage }
                let passes = interlace == 0 ? [(0, 0, 1, 1)] : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
                for (x, y, dx, dy) in passes where width > x && height > y {
                    let w = (width - x + dx - 1) / dx, h = (height - y + dy - 1) / dy
                    rows.append((h, (w * count * depth + 7) / 8))
                }
            }
            if type == "IDAT" { compressed.append(data[(offset + 8)..<(offset + 8 + length)]) }
            offset += length + 12
            if type == "IEND" {
                guard length == 0, !compressed.isEmpty, offset == data.count else { throw AvatarError.invalidImage }
                try validateScanlines(compressed, rows: rows)
                return
            }
        }
        throw AvatarError.invalidImage
    }
    private static func validateScanlines(_ data: Data, rows: [(count: Int, bytes: Int)]) throws {
        // A CRC-valid stream can still contain only half the declared rows.
        // Inflate into a fixed buffer, checking size/filter bytes for every
        // scanline (including Adam7 passes), without allocating a full raster.
        let expected = rows.reduce(0) { $0 + $1.count * ($1.bytes + 1) }
        guard !rows.isEmpty, data.count <= Int(UInt32.max) else { throw AvatarError.invalidImage }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AvatarError.invalidImage }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var pass = 0, rowsLeft = rows[0].count, remaining = 0
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            while true {
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard stream.total_out <= expected, status == Z_OK || status == Z_STREAM_END else { throw AvatarError.invalidImage }
                var index = 0
                while index < produced {
                    if remaining == 0 {
                        if rowsLeft == 0 { pass += 1; if pass < rows.count { rowsLeft = rows[pass].count } }
                        guard pass < rows.count, buffer[index] <= 4 else { throw AvatarError.invalidImage }
                        rowsLeft -= 1; remaining = rows[pass].bytes; index += 1
                    }
                    let step = min(remaining, produced - index)
                    remaining -= step; index += step
                }
                if status == Z_STREAM_END {
                    guard stream.total_out == expected, stream.avail_in == 0 else { throw AvatarError.invalidImage }
                    return
                }
                guard produced > 0 else { throw AvatarError.invalidImage }
            }
        }
    }
    private static func context() throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AvatarError.invalidImage }
        context.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.interpolationQuality = .high
        return context
    }
    fileprivate static func render(image: CGImage, rect: CGRect) throws -> ReceiverAvatar {
        let context = try context()
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw AvatarError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AvatarError.invalidImage }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw AvatarError.invalidImage }
        return try ReceiverAvatar(png: data as Data)
    }
    func materialize(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(hash + ".png")
        if (try? Data(contentsOf: url)) != png {
            try png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }
}
