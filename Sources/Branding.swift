import Cocoa

enum AimDropArtwork {
    static func menuBarIcon() -> NSImage? {
        let image = Bundle.main.url(forResource: "AimDropStatus", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "AimDrop")
        if let image, image.size.width > 0 {
            image.size = NSSize(width: 20, height: 20 * image.size.height / image.size.width)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = "AimDrop"
        return image
    }

    static let applicationIcon: NSImage? = {
        Bundle.main.url(forResource: "AimDrop", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "AimDrop")
    }()
}
