import Cocoa
import ImageIO

@main struct PendingFilePreviewChecks {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Preview did not settle")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        L10n.configure(.english)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("notes.txt")
        try String(repeating: "Example text.\n", count: 3000).write(to: textURL, atomically: true, encoding: .utf8)
        var textResult: PendingFilePreviewContent?
        let cancelText = PendingFilePreviewLoader.load(textURL) { result in DispatchQueue.main.async { textResult = result } }
        wait { textResult != nil }
        guard case .text(let snippet)? = textResult else { fatalError("No TXT preview") }
        precondition(snippet.hasPrefix("Example text.") && snippet.count <= 1600)
        cancelText()

        let imageURL = root.appendingPathComponent("large.png")
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        var imageResult: PendingFilePreviewContent?
        let cancelImage = PendingFilePreviewLoader.load(imageURL) { result in DispatchQueue.main.async { imageResult = result } }
        wait { imageResult != nil }
        guard case .image(let bitmap)? = imageResult else { fatalError("No image preview") }
        precondition(bitmap.width <= 640 && bitmap.height <= 640 && bitmap.width > bitmap.height)
        cancelImage()

        let host = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 250, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let first = NSView(frame: NSRect(x: 0, y: 70, width: 250, height: 24))
        let second = NSView(frame: NSRect(x: 0, y: 40, width: 250, height: 24))
        host.contentView!.addSubview(first); host.contentView!.addSubview(second)
        var completions: [PendingFilePreviewLoader.Completion] = []
        var cancellations = 0
        let preview = PendingFilePreviewController(delay: 0.02) { _, completion in
            completions.append(completion)
            return { cancellations += 1 }
        }
        preview.schedule(url: imageURL, transferID: "first", anchor: first)
        preview.hide(for: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(completions.isEmpty && !preview.visibleForChecks, "A passing hover must not start loading")
        preview.schedule(url: imageURL, transferID: "first", anchor: first)
        wait { completions.count == 1 && preview.visibleForChecks }
        preview.schedule(url: textURL, transferID: "second", anchor: second)
        wait { completions.count == 2 && preview.visibleForChecks }
        precondition(cancellations == 1)
        completions[0](.text("obsolete"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(preview.textForChecks != "obsolete")
        preview.hide(for: first)
        precondition(preview.visibleForChecks, "Leaving an old row must not dismiss the current row's preview")
        completions[1](.text("current"))
        wait { preview.textForChecks == "current" }
        preview.hide()
        completions[1](.text("late"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(!preview.visibleForChecks && preview.textForChecks.isEmpty)
        print("PASS: bounded image/TXT previews, delayed hover, cancellation, row switching and no stale preview resurrection")
    }
}
