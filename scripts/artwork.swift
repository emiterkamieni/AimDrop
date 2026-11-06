import Cocoa

// Render the user's unmodified SVG into the local macOS icon set.
// Palette: air #2CBDF1, signal #1876E8, depth #0C479D, porcelain #F3FBFF.
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func png(size: Int, draw: () -> Void) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "AirFolder.Artwork", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AirFolder.Artwork", code: 2)
    }
    return data
}

guard CommandLine.arguments.count == 3 else { fatalError("Usage: artwork source.svg output-directory") }
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let mark = NSImage(contentsOf: source), mark.isValid else { fatalError("Cannot decode the supplied SVG") }
let whiteMark = NSImage(size: mark.size, flipped: false) { rect in
    mark.draw(in: rect)
    color(0xF3FBFF).setFill()
    rect.fill(using: .sourceAtop)
    return true
}

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0C479D).withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -9)
    shadow.set()
    color(0x1876E8).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colorsAndLocations: (color(0x0C479D), 0), (color(0x1876E8), 0.42),
               (color(0x2CBDF1), 1))!.draw(in: tile, angle: 65)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let width: CGFloat = 690
    let height = width * mark.size.height / mark.size.width
    let rect = NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 6, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let relief = NSShadow()
    relief.shadowColor = color(0x0C479D).withAlphaComponent(0.20)
    relief.shadowBlurRadius = 9
    relief.shadowOffset = NSSize(width: 0, height: -5)
    relief.set()
    whiteMark.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

let iconset = output.appendingPathComponent("AirFolder.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: points * scale, draw: drawIcon)
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try png(size: 1024, draw: drawIcon).write(to: output.appendingPathComponent("AirFolder.png"))
// Export the exact same vector as a template PDF for crisp menu-bar drawing.
let pdf = NSMutableData()
var box = CGRect(x: 0, y: 0, width: mark.size.width, height: mark.size.height)
guard let consumer = CGDataConsumer(data: pdf), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
    fatalError("Cannot create menu-bar artwork")
}
context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
mark.draw(in: box)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
try (pdf as Data).write(to: output.appendingPathComponent("AirFolderStatus.pdf"))
print("Rendered AirFolder icon and menu-bar template from \(source.lastPathComponent)")
