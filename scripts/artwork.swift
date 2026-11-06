import Cocoa

// Render the user's unmodified SVG into the local macOS icon set.
// Keep the supplied black mark on a light native tile; the menu-bar template
// uses the original silhouette and follows the system's light/dark appearance.
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
        throw NSError(domain: "AimDrop.Artwork", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AimDrop.Artwork", code: 2)
    }
    return data
}

guard CommandLine.arguments.count == 3 else { fatalError("Usage: artwork source.svg output-directory") }
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let mark = NSImage(contentsOf: source), mark.isValid else { fatalError("Cannot decode the supplied SVG") }
func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -9)
    shadow.set()
    color(0xF7F7F7).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.8).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let width: CGFloat = 690
    let height = width * mark.size.height / mark.size.width
    let rect = NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 6, width: width, height: height)
    mark.draw(in: rect)
}

func drawAvatar() {
    // The contact image has its own circular canvas, without the macOS icon tile.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    let width: CGFloat = 710
    let height = width * mark.size.height / mark.size.width
    mark.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 8,
                        width: width, height: height))
}

let iconset = output.appendingPathComponent("AimDrop.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: points * scale, draw: drawIcon)
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try png(size: 1024, draw: drawIcon).write(to: output.appendingPathComponent("AimDrop.png"))
try png(size: 1024, draw: drawAvatar).write(to: output.appendingPathComponent("AimDropAvatar.png"))
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
try (pdf as Data).write(to: output.appendingPathComponent("AimDropStatus.pdf"))
print("Rendered AimDrop icon and menu-bar template from \(source.lastPathComponent)")
