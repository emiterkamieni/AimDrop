import Cocoa

enum WindowPlacement {
    static func activeScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func centeredOrigin(for size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: size.width <= visibleFrame.width ? visibleFrame.midX - size.width / 2 : visibleFrame.minX,
                y: size.height <= visibleFrame.height ? visibleFrame.midY - size.height / 2 : visibleFrame.maxY - size.height)
    }

    static func center(_ window: NSWindow, on preferredScreen: NSScreen? = nil) {
        // A display can disappear while an asynchronous update check is running.
        let display = preferredScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let connected = display.flatMap { number in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == number }
        }
        guard let screen = connected ?? activeScreen() else { return }
        window.setFrameOrigin(centeredOrigin(for: window.frame.size, in: screen.visibleFrame))
    }
}
