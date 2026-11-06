import Cocoa

enum AirFolderArtwork {
    static func menuBarIcon() -> NSImage? {
        let image = Bundle.main.url(forResource: "AirFolderStatus", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "AirFolder")
        image?.size = NSSize(width: 22, height: 22 * 96 / 131.6)
        image?.isTemplate = true
        image?.accessibilityDescription = "AirFolder"
        return image
    }

    static let applicationIcon: NSImage? = {
        Bundle.main.url(forResource: "AirFolder", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "AirFolder")
    }()
}
